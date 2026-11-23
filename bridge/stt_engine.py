"""GPU-accelerated Speech-to-Text engine (faster-whisper large-v3-turbo + Silero VAD) for DGX Spark."""
from __future__ import annotations

import logging
import os
import time
import numpy as np

log = logging.getLogger("g2.stt")

DEFAULT_MODEL = os.environ.get("G2_WHISPER_MODEL", "large-v3-turbo")
DEFAULT_DEVICE = os.environ.get("G2_WHISPER_DEVICE", "auto")
DEFAULT_COMPUTE = os.environ.get("G2_WHISPER_COMPUTE", "auto")
DEFAULT_PROMPT = os.environ.get(
    "G2_STT_PROMPT",
    "Even Realities G2 스마트 안경, DGX Spark, Tailscale, Antigravity, 자연스러운 한국어와 영어 혼용 대화입니다.",
)

# Known Whisper hallucination phrases on near-silence
HALLUCINATION_FILTERS = {
    "시청해 주셔서 감사합니다",
    "시청해주셔서 감사합니다",
    "구독과 좋아요",
    "MBC 뉴스",
    "감사합니다.",
    "Thank you.",
    "Thanks for watching.",
    "you",
}


class SparkSTTEngine:
    def __init__(self) -> None:
        self.model = None
        self.model_name = DEFAULT_MODEL
        self.device = "unknown"
        self.compute_type = "unknown"
        self.ready = False

    def load_and_warmup(self) -> None:
        from faster_whisper import WhisperModel

        device = DEFAULT_DEVICE
        compute = DEFAULT_COMPUTE
        if device == "auto":
            try:
                import ctranslate2
                device = "cuda" if ctranslate2.get_cuda_device_count() > 0 else "cpu"
            except Exception:
                device = "cpu"
        if compute == "auto":
            compute = "float16" if device == "cuda" else "int8"

        self.device = device
        self.compute_type = compute
        t0 = time.monotonic()
        log.info("Loading faster-whisper model=%s device=%s compute=%s ...", self.model_name, device, compute)
        self.model = WhisperModel(self.model_name, device=device, compute_type=compute)

        # Warm up CUDA/cuDNN kernels so the very first voice turn has zero cold-start lag.
        dummy = np.zeros(16000, dtype=np.float32)
        list(self.model.transcribe(dummy, beam_size=1, vad_filter=False)[0])
        self.ready = True
        log.info("STT ready in %.2fs (model=%s, device=%s)", time.monotonic() - t0, self.model_name, device)

    def transcribe(
        self,
        pcm: np.ndarray,
        language: str | None = None,
        fast_partial: bool = False,
    ) -> tuple[str, str, float]:
        """Returns (text, detected_language, elapsed_ms)."""
        if not self.ready or self.model is None or pcm.size < 3200:  # < 200ms
            return "", language or "ko", 0.0

        lang_arg = None if (not language or language == "auto") else language
        t0 = time.monotonic()
        segments, info = self.model.transcribe(
            pcm,
            language=lang_arg,
            beam_size=1 if fast_partial else 5,
            best_of=1 if fast_partial else 5,
            temperature=0.0,
            vad_filter=True,
            vad_parameters={
                "min_silence_duration_ms": 350 if fast_partial else 450,
                "speech_pad_ms": 180,
            },
            condition_on_previous_text=not fast_partial,
            initial_prompt=DEFAULT_PROMPT,
            without_timestamps=True,
        )
        parts = [seg.text.strip() for seg in segments if seg.text and seg.text.strip()]
        text = " ".join(parts).strip()
        elapsed_ms = (time.monotonic() - t0) * 1000.0

        if text in HALLUCINATION_FILTERS:
            text = ""
        detected = getattr(info, "language", None) or (lang_arg or "ko")
        return text, detected, elapsed_ms
