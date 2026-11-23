"""DGX Spark Real-Time G2 Voice & `agy` Bridge Server (FastAPI + WebSocket).

Deploy identically on spark01 (100.101.25.64) and spark02 (100.101.25.65) over Tailscale.
Streams G2 raw 16kHz LC3 audio -> CUDA faster-whisper large-v3-turbo -> warm `agy` stream-json
back to the iPhone G2 OS app in real time.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import socket
import time
from contextlib import asynccontextmanager

import numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from agy_runner import WarmAgySession, resolve_agy_binary
from audio_decoder import G2AudioDecoder, SAMPLE_RATE, chunk_rms
from stt_engine import SparkSTTEngine

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("g2.server")

stt = SparkSTTEngine()
agy_sessions: dict[str, WarmAgySession] = {
    "even_ai": WarmAgySession("even_ai", effort=os.environ.get("G2_DEFAULT_EFFORT", "low")),
    "translate": WarmAgySession("translate", effort="low"),
    "conversate": WarmAgySession("conversate", effort="low"),
}


@asynccontextmanager
async def lifespan(_app: FastAPI):
    loop = asyncio.get_running_loop()
    await loop.run_in_executor(None, stt.load_and_warmup)
    # Pre-spawn the primary Even AI warm agy process so turn #1 is already hot.
    try:
        await agy_sessions["even_ai"].ensure_started()
    except Exception as exc:
        log.warning("Pre-warming agy failed (will retry on first request): %s", exc)
    yield
    for sess in agy_sessions.values():
        await sess.reset()


app = FastAPI(title="G2 Spark Voice & AGY Bridge", lifespan=lifespan)


@app.get("/health")
async def health():
    return {
        "ok": True,
        "host": socket.gethostname(),
        "stt_ready": stt.ready,
        "stt_backend": stt.backend,
        "stt_model": stt.model_name,
        "stt_device": stt.device,
        "stt_compute": stt.compute_type,
        "agy_bin": resolve_agy_binary(),
    }


def _build_mode_prompt(mode: str, transcript: str, src_lang: str, dst_lang: str) -> str:
    if mode == "translate":
        lang_names = {"ko": "한국어", "en": "영어", "ja": "일본어", "zh": "중국어", "auto": "자동"}
        dst = lang_names.get(dst_lang, dst_lang)
        if src_lang == "auto":
            return f"다음 발화를 자연스러운 {dst}로만 번역해. (만약 이미 {dst}면 자연스러운 영어로 번역해.)\n발화: {transcript}"
        src = lang_names.get(src_lang, src_lang)
        return f"다음 {src} 발화를 자연스러운 {dst}로만 번역해:\n{transcript}"
    if mode == "conversate":
        return f"[실시간 회의 발화]\n{transcript}\n\n(전문용어 설명이나 바로 참고할 핵심 포인트가 있을 때만 1~3줄로 아주 간결히 답해. 일상 잡담이면 핵심 1줄 요약만.)"
    return transcript


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    host = socket.gethostname()
    log.info("Client connected to %s", host)
    await ws.send_json({"type": "hello", "host": host, "stt_ready": stt.ready, "stt_model": stt.model_name})

    decoder = G2AudioDecoder("lc3_16k")
    pcm_chunks: list[np.ndarray] = []
    audio_active = False
    mode = "even_ai"
    src_lang = "auto"
    dst_lang = "ko"
    effort = os.environ.get("G2_DEFAULT_EFFORT", "low")
    last_partial_at = 0.0
    last_partial_text = ""
    speech_detected_at = 0.0
    last_voice_at = 0.0
    conversate_history: list[str] = []

    loop = asyncio.get_running_loop()

    async def run_agy_turn(turn_mode: str, prompt_text: str) -> None:
        session = agy_sessions.get(turn_mode) or agy_sessions["even_ai"]
        await ws.send_json({"type": "ai_status", "mode": turn_mode, "status": "agy 생각 중..."})
        async for evt in session.ask_stream(prompt_text, effort=effort):
            await ws.send_json(evt)

    async def commit_audio_utterance(is_continuous_auto: bool) -> None:
        nonlocal pcm_chunks, last_partial_text, speech_detected_at, last_voice_at
        if not pcm_chunks:
            if not is_continuous_auto:
                await ws.send_json({"type": "stt_final", "mode": mode, "text": "", "elapsed_ms": 0})
            return

        full_pcm = np.concatenate(pcm_chunks)
        pcm_chunks = []
        last_partial_text = ""
        speech_detected_at = 0.0
        last_voice_at = 0.0

        text, detected_lang, elapsed_ms = await loop.run_in_executor(
            None,
            lambda: stt.transcribe(full_pcm, language=None if src_lang == "auto" else src_lang, fast_partial=False),
        )
        await ws.send_json(
            {
                "type": "stt_final",
                "mode": mode,
                "text": text,
                "language": detected_lang,
                "elapsed_ms": round(elapsed_ms, 1),
            }
        )
        if not text:
            return

        if mode == "transcribe":
            return

        if mode == "conversate":
            conversate_history.append(text)
            if len(conversate_history) > 40:
                conversate_history.pop(0)

        prompt = _build_mode_prompt(mode, text, src_lang, dst_lang)
        await run_agy_turn(mode, prompt)

    try:
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                break

            # 1. Binary audio frames streamed live from G2 0x6402
            if msg.get("bytes") is not None:
                if not audio_active:
                    continue
                try:
                    samples = decoder.decode(msg["bytes"])
                except Exception as exc:
                    await ws.send_json({"type": "error", "message": str(exc)})
                    continue
                if samples.size == 0:
                    continue

                pcm_chunks.append(samples)
                now = time.monotonic()
                rms = chunk_rms(samples)
                if rms > 0.015:
                    if speech_detected_at == 0.0:
                        speech_detected_at = now
                    last_voice_at = now

                # Stream live incremental captions every 0.65s while speaking
                total_samples = sum(c.size for c in pcm_chunks)
                if total_samples >= int(SAMPLE_RATE * 0.45) and (now - last_partial_at) >= 0.65:
                    last_partial_at = now
                    snapshot = np.concatenate(pcm_chunks[-40:])  # keep partial window fast
                    partial_text, _, p_ms = await loop.run_in_executor(
                        None,
                        lambda: stt.transcribe(snapshot, language=None if src_lang == "auto" else src_lang, fast_partial=True),
                    )
                    if partial_text and partial_text != last_partial_text:
                        last_partial_text = partial_text
                        await ws.send_json(
                            {"type": "stt_partial", "mode": mode, "text": partial_text, "elapsed_ms": round(p_ms, 1)}
                        )

                # In continuous modes (translate / conversate / transcribe), auto-commit on ~1.2s pause after speech
                if mode in ("translate", "conversate", "transcribe"):
                    voiced_dur = (last_voice_at - speech_detected_at) if speech_detected_at > 0 else 0.0
                    silence_dur = (now - last_voice_at) if last_voice_at > 0 else 0.0
                    if voiced_dur >= 0.6 and silence_dur >= 1.25:
                        await commit_audio_utterance(is_continuous_auto=True)
                    elif total_samples >= SAMPLE_RATE * 14:
                        # Hard cap continuous chunk at 14s to keep latency crisp
                        await commit_audio_utterance(is_continuous_auto=True)
                continue

            # 2. JSON control frames
            raw_text = msg.get("text")
            if not raw_text:
                continue
            try:
                data = json.loads(raw_text)
            except json.JSONDecodeError:
                continue

            msg_type = data.get("type")
            if msg_type == "ping":
                await ws.send_json({"type": "pong", "host": host})
            elif msg_type == "start_audio":
                mode = data.get("mode", "even_ai")
                src_lang = data.get("src_lang", "auto")
                dst_lang = data.get("dst_lang", "ko")
                effort = data.get("effort", effort)
                codec = data.get("codec", "lc3_16k")
                decoder.reset(codec)
                pcm_chunks = []
                last_partial_text = ""
                last_partial_at = 0.0
                speech_detected_at = 0.0
                last_voice_at = 0.0
                audio_active = True
                await ws.send_json({"type": "audio_ack", "mode": mode, "host": host})
            elif msg_type == "stop_audio":
                audio_active = False
                await commit_audio_utterance(is_continuous_auto=False)
            elif msg_type == "text_prompt":
                turn_mode = data.get("mode", "even_ai")
                effort = data.get("effort", effort)
                text = (data.get("text") or "").strip()
                if turn_mode == "conversate" and text == "__SUMMARIZE__":
                    joined = "\n".join(f"- {line}" for line in conversate_history[-25:])
                    if not joined:
                        await ws.send_json({"type": "ai_done", "mode": "conversate", "text": "아직 기록된 회의 내용이 없습니다.", "commands": []})
                        continue
                    text = f"지금까지 회의 내용을 핵심 요약 3줄과 액션 아이템으로 정리해줘:\n{joined}"
                if text:
                    await run_agy_turn(turn_mode, text)
            elif msg_type == "reset_session":
                target_mode = data.get("mode", "even_ai")
                if target_mode == "conversate":
                    conversate_history.clear()
                if target_mode in agy_sessions:
                    await agy_sessions[target_mode].reset(effort=effort)
                await ws.send_json({"type": "session_reset", "mode": target_mode})

    except WebSocketDisconnect:
        log.info("Client disconnected from %s", host)
    except Exception as exc:
        log.exception("WebSocket session error: %s", exc)
