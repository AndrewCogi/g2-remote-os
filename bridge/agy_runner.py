"""Persistent warm `agy` CLI runner using official `--input-format stream-json --output-format stream-json`.

Keeps one warm `agy` process per mode (even_ai, translate, conversate) so turns skip startup
overhead (~0.9s warm latency vs cold-start) and stream live tool status + `text_delta` tokens.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shutil
from typing import Any, AsyncIterator

log = logging.getLogger("g2.agy")

CMD_PATTERN = re.compile(r"\[G2CMD:(\{[^\]]+\})\]")

SYSTEM_PRIMERS: dict[str, str] = {
    "even_ai": (
        "너는 Even Realities G2 스마트 안경(576x288 녹색 디스플레이) 위의 개인 음성 비서 'Even AI (Antigravity)'다.\n"
        "규칙:\n"
        "1. 답변은 안경에서 한눈에 읽기 좋게 핵심부터 간결하게 한국어로 작성하라(불필요한 인사·서론·마크다운 코드블록 금지).\n"
        "2. 사용자가 안경/OS 제어를 음성으로 요청하면 답변 맨 끝에 아래 JSON 태그 중 하나를 정확히 붙여라:\n"
        "   - 타이머: [G2CMD:{\"cmd\":\"timer\",\"seconds\":300}]\n"
        "   - 알람: [G2CMD:{\"cmd\":\"alarm\",\"hour\":7,\"minute\":30,\"label\":\"기상\"}]\n"
        "   - 할일 추가: [G2CMD:{\"cmd\":\"task\",\"title\":\"우유 사기\"}]\n"
        "   - 밝기 조절(1~50): [G2CMD:{\"cmd\":\"brightness\",\"level\":35}]\n"
        "   - 무음 모드: [G2CMD:{\"cmd\":\"silent\",\"enabled\":true}]\n"
        "3. 일반 질문·웹검색·복합 조사는 순정 Even AI보다 훨씬 정확하고 깊이 있게 답하되, 안경에 읽기 좋은 짧은 문단·불릿으로 정리하라."
    ),
    "translate": (
        "너는 초고속 실시간 동시통역기다. 설명·인사·따옴표 없이 오직 번역된 결과 문장 1~2줄만 즉시 출력하라."
    ),
    "conversate": (
        "너는 Even Realities G2 안경의 실시간 회의 코파일럿(Conversate)이다.\n"
        "대화 발화가 들어오면:\n"
        "- 생소한 전문용어/인물/개념이 있으면 1줄 정의 제공\n"
        "- 질문이나 논의 쟁점이 있으면 바로 꺼내 쓸 수 있는 핵심 포인트 1~2줄 제안\n"
        "- '요약' 요청 시 핵심 논의 + 액션 아이템 3~5줄 불릿 정리\n"
        "불필요한 서론 없이 G2 안경에 바로 띄울 간결한 한국어로 답하라."
    ),
}


def resolve_agy_binary() -> str:
    env_bin = os.environ.get("G2_AGY_BIN")
    if env_bin and os.path.isfile(env_bin):
        return env_bin
    found = shutil.which("agy")
    if found:
        return found
    for candidate in (
        os.path.expanduser("~/.local/bin/agy"),
        "/usr/local/bin/agy",
        "/opt/homebrew/bin/agy",
    ):
        if os.path.isfile(candidate):
            return candidate
    return "agy"


def extract_g2_commands(text: str) -> tuple[str, list[dict[str, Any]]]:
    """Strips `[G2CMD:{...}]` directives from display text and returns parsed command dicts."""
    commands: list[dict[str, Any]] = []

    def _collect(match: re.Match[str]) -> str:
        raw = match.group(1)
        try:
            obj = json.loads(raw)
            if isinstance(obj, dict) and "cmd" in obj:
                commands.append(obj)
        except Exception:
            pass
        return ""

    cleaned = CMD_PATTERN.sub(_collect, text).strip()
    return cleaned, commands


class WarmAgySession:
    """Maintains a single persistent `agy --input-format stream-json --output-format stream-json` process."""

    def __init__(self, mode: str, effort: str = "low") -> None:
        self.mode = mode
        self.effort = effort
        self.agy_bin = resolve_agy_binary()
        self.proc: asyncio.subprocess.Process | None = None
        self.conversation_id: str | None = None
        self._primed = False
        self._lock = asyncio.Lock()

    async def ensure_started(self) -> None:
        if self.proc is not None and self.proc.returncode is None:
            return
        cmd = [
            self.agy_bin,
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--effort",
            self.effort,
            "--disable-slash-commands",
        ]
        if os.environ.get("G2_AGY_AUTO_APPROVE", "0") == "1":
            cmd.append("--dangerously-skip-permissions")
        model = os.environ.get("G2_AGY_MODEL", "").strip()
        if model:
            cmd.extend(["--model", model])

        log.info("Spawning warm agy session mode=%s effort=%s: %s", self.mode, self.effort, " ".join(cmd))
        self.proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=os.environ.get("G2_AGY_WORKDIR", os.path.expanduser("~")),
        )
        self._primed = False
        self.conversation_id = None

    async def reset(self, effort: str | None = None) -> None:
        async with self._lock:
            if effort:
                self.effort = effort
            await self._kill_locked()

    async def _kill_locked(self) -> None:
        if self.proc is not None:
            try:
                if self.proc.stdin:
                    self.proc.stdin.close()
                self.proc.terminate()
                await asyncio.wait_for(self.proc.wait(), timeout=2.0)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
            self.proc = None
        self._primed = False
        self.conversation_id = None

    async def ask_stream(self, user_prompt: str, effort: str | None = None) -> AsyncIterator[dict[str, Any]]:
        """Feeds one turn to the warm agy process and yields streaming bridge events."""
        async with self._lock:
            if effort and effort != self.effort:
                self.effort = effort
                await self._kill_locked()

            await self.ensure_started()
            assert self.proc is not None and self.proc.stdin is not None and self.proc.stdout is not None

            full_prompt = user_prompt
            if not self._primed:
                primer = SYSTEM_PRIMERS.get(self.mode, "")
                if primer:
                    full_prompt = f"[시스템 지침]\n{primer}\n\n[사용자 요청]\n{user_prompt}"
                self._primed = True

            payload = json.dumps({"event": "user", "message": {"content": full_prompt}}, ensure_ascii=False) + "\n"
            try:
                self.proc.stdin.write(payload.encode("utf-8"))
                await self.proc.stdin.drain()
            except Exception as exc:
                log.warning("agy stdin write failed (%s), respawning...", exc)
                await self._kill_locked()
                await self.ensure_started()
                assert self.proc is not None and self.proc.stdin is not None and self.proc.stdout is not None
                self._primed = True
                self.proc.stdin.write(payload.encode("utf-8"))
                await self.proc.stdin.drain()

            accumulated = ""
            while True:
                raw_line = await self.proc.stdout.readline()
                if not raw_line:
                    err_text = ""
                    if self.proc.stderr:
                        try:
                            err_bytes = await asyncio.wait_for(self.proc.stderr.read(), timeout=0.5)
                            err_text = err_bytes.decode("utf-8", errors="replace").strip()
                        except Exception:
                            pass
                    await self._kill_locked()
                    yield {
                        "type": "error",
                        "message": f"agy 세션 종료됨: {err_text[:200] or '재연결 필요'}",
                    }
                    return

                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line:
                    continue
                try:
                    evt = json.loads(line)
                except json.JSONDecodeError:
                    continue

                kind = evt.get("event")
                if kind == "init":
                    self.conversation_id = evt.get("conversation_id")
                    continue

                if kind == "step_update":
                    su = evt.get("step_update") or {}
                    step_type = su.get("step_type", "")
                    state = su.get("state", "")
                    if step_type == "tool" and state == "ACTIVE":
                        tool_name = su.get("tool_name") or "도구"
                        label = _friendly_tool_label(tool_name)
                        yield {"type": "ai_status", "mode": self.mode, "status": label}
                    elif step_type == "agent_response":
                        delta = su.get("text_delta") or ""
                        if delta:
                            accumulated += delta
                            preview, _ = extract_g2_commands(accumulated)
                            yield {
                                "type": "ai_delta",
                                "mode": self.mode,
                                "delta": delta,
                                "full_text": preview,
                            }
                    continue

                if kind == "result":
                    res = evt.get("result") or {}
                    status = res.get("status", "SUCCESS")
                    final_raw = (res.get("response") or accumulated).strip()
                    clean_text, commands = extract_g2_commands(final_raw)
                    if status != "SUCCESS" and not clean_text:
                        yield {
                            "type": "error",
                            "mode": self.mode,
                            "message": res.get("error") or f"agy 오류 ({status})",
                        }
                    else:
                        yield {
                            "type": "ai_done",
                            "mode": self.mode,
                            "text": clean_text,
                            "commands": commands,
                            "duration_s": res.get("duration_seconds"),
                            "conversation_id": res.get("conversation_id") or self.conversation_id,
                        }
                    return


def _friendly_tool_label(tool_name: str) -> str:
    low = tool_name.lower()
    if "search" in low or "web" in low:
        return "웹 검색 중..."
    if "command" in low or "shell" in low:
        return "작업 실행 중..."
    if "read" in low or "file" in low:
        return "문서 확인 중..."
    return f"{tool_name} 처리 중..."
