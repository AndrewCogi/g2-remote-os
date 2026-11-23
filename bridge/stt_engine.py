"""GPU-accelerated Speech-to-Text engine for NVIDIA DGX Spark (Blackwell GB10 ARM64).

Backend auto-selection priority:
  1. faster-whisper CUDA (only if ctranslate2 was built with CUDA)
  2. PyTorch CUDA (`openai/whisper-large-v3-turbo`, bfloat16 + SDPA + Silero VAD)
     -> Native Blackwell GB10 GPU execution on DGX Spark aarch64 (no C++ compile needed)
  3. faster-whisper CPU (int8) fallback
"""
from __future__ import annotations

import logging
import os
import threading
import time
import numpy as np

log = logging.getLogger("g2.stt")

DEFAULT_MODEL = os.environ.get("G2_WHISPER_MODEL", "large-v3-turbo")
DEFAULT_BACKEND = os.environ.get("G2_STT_BACKEND", "auto")  # auto | torch | faster_whisper
DEFAULT_DEVICE = os.environ.get("G2_WHISPER_DEVICE", "auto")
DEFAULT_COMPUTE = os.environ.get("G2_WHISPER_COMPUTE", "auto")
DEFAULT_PROMPT = os.environ.get(
    "G2_STT_PROMPT",
    "Even Realities G2 스마트 안경, DGX Spark, Tailscale, Antigravity, 자연스러운 한국어와 영어 혼용 대화입니다.",
)

HF_MODEL_MAP = {
    "large-v3-turbo": "openai/whisper-large-v3-turbo",
    "turbo": "openai/whisper-large-v3-turbo",
    "large-v3": "openai/whisper-large-v3",
    "medium": "openai/whisper-medium",
    "small": "openai/whisper-small",
}

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
    ".",
}


class SparkSTTEngine:
    def __init__(self) -> None:
        self.backend = "uninitialized"
        self.model = None  # faster-whisper WhisperModel
        self.torch_model = None
        self.processor = None
        self.prompt_ids = None
        self.sot_id: int | None = None
        self.torch_dtype = None
        self.model_name = DEFAULT_MODEL
        self.device = "unknown"
        self.compute_type = "unknown"
        self.ready = False
        self._lock = threading.Lock()

    def _has_ct2_cuda(self) -> bool:
        try:
            import ctranslate2
            return ctranslate2.get_cuda_device_count() > 0
        except Exception:
            return False

    def _has_torch_cuda(self) -> bool:
        try:
            import torch
            return bool(torch.cuda.is_available())
        except Exception:
            return False

    def load_and_warmup(self) -> None:
        t0 = time.monotonic()

        use_backend = DEFAULT_BACKEND
        if use_backend == "auto":
            if self._has_ct2_cuda():
                use_backend = "faster_whisper"
            elif self._has_torch_cuda():
                use_backend = "torch"
            else:
                use_backend = "faster_whisper"

        if use_backend == "torch":
            self._load_torch_cuda(t0)
        else:
            self._load_faster_whisper(t0)

    def _load_torch_cuda(self, t0: float) -> None:
        import torch
        from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor

        hf_model_id = HF_MODEL_MAP.get(self.model_name, self.model_name)
        gpu_name = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "cpu"
        device_str = "cuda:0" if torch.cuda.is_available() else "cpu"
        dtype = torch.bfloat16 if (torch.cuda.is_available() and torch.cuda.is_bf16_supported()) else (
            torch.float16 if torch.cuda.is_available() else torch.float32
        )

        self.backend = "torch-cuda" if torch.cuda.is_available() else "torch-cpu"
        self.device = f"cuda ({gpu_name})" if torch.cuda.is_available() else "cpu"
        self.compute_type = str(dtype).replace("torch.", "")
        self.torch_dtype = dtype

        log.info(
            "Loading PyTorch Whisper model=%s device=%s dtype=%s (SDPA) ...",
            hf_model_id, self.device, self.compute_type,
        )

        self.processor = AutoProcessor.from_pretrained(hf_model_id)
        load_kwargs = {
            "low_cpu_mem_usage": True,
            "use_safetensors": True,
            "attn_implementation": "sdpa",
        }
        try:
            self.torch_model = AutoModelForSpeechSeq2Seq.from_pretrained(
                hf_model_id, dtype=dtype, **load_kwargs
            )
        except TypeError:
            self.torch_model = AutoModelForSpeechSeq2Seq.from_pretrained(
                hf_model_id, torch_dtype=dtype, **load_kwargs
            )

        self.torch_model.to(device_str)
        self.torch_model.eval()
        if hasattr(self.torch_model, "generation_config"):
            self.torch_model.generation_config.forced_decoder_ids = None

        self.sot_id = self.processor.tokenizer.convert_tokens_to_ids("<|startoftranscript|>")
        try:
            pids = self.processor.get_prompt_ids(DEFAULT_PROMPT, return_tensors="pt")
            self.prompt_ids = pids.to(device_str)
        except Exception as exc:
            log.warning("Could not prepare Whisper prompt_ids: %s", exc)
            self.prompt_ids = None

        # Warm up GPU kernels (both fixed-language and auto-language paths)
        dummy = np.zeros(16000, dtype=np.float32)
        self._transcribe_torch(dummy, language="ko", fast_partial=True, use_vad=False)
        self._transcribe_torch(dummy, language=None, fast_partial=True, use_vad=False)

        self.ready = True
        log.info(
            "GPU STT ready in %.2fs (backend=%s, model=%s, device=%s, dtype=%s)",
            time.monotonic() - t0, self.backend, hf_model_id, self.device, self.compute_type,
        )

    def _load_faster_whisper(self, t0: float) -> None:
        from faster_whisper import WhisperModel

        device = DEFAULT_DEVICE
        compute = DEFAULT_COMPUTE
        if device == "auto":
            device = "cuda" if self._has_ct2_cuda() else "cpu"
        if compute == "auto":
            compute = "float16" if device == "cuda" else "int8"

        self.backend = f"faster-whisper-{device}"
        self.device = device
        self.compute_type = compute
        log.info("Loading faster-whisper model=%s device=%s compute=%s ...", self.model_name, device, compute)
        self.model = WhisperModel(self.model_name, device=device, compute_type=compute)

        dummy = np.zeros(16000, dtype=np.float32)
        list(self.model.transcribe(dummy, beam_size=1, vad_filter=False)[0])
        self.ready = True
        log.info("STT ready in %.2fs (backend=%s, model=%s, device=%s)", time.monotonic() - t0, self.backend, self.model_name, device)

    def _apply_silero_vad(self, pcm: np.ndarray, fast_partial: bool) -> np.ndarray:
        """Trim silence using Silero ONNX VAD (<3ms) to eliminate Whisper silence hallucinations."""
        try:
            from faster_whisper.vad import VadOptions, get_speech_timestamps

            opts = VadOptions(
                threshold=0.45,
                min_speech_duration_ms=180,
                min_silence_duration_ms=350 if fast_partial else 450,
                speech_pad_ms=180,
            )
            chunks = get_speech_timestamps(pcm, vad_options=opts, sampling_rate=16000)
            if not chunks:
                return np.empty(0, dtype=np.float32)
            parts = [pcm[int(c["start"]):int(c["end"])] for c in chunks]
            return np.concatenate(parts) if parts else np.empty(0, dtype=np.float32)
        except Exception as exc:
            log.debug("Silero VAD skipped (%s), using raw PCM", exc)
            return pcm

    def _transcribe_torch(
        self,
        pcm: np.ndarray,
        language: str | None,
        fast_partial: bool,
        use_vad: bool = True,
    ) -> tuple[str, str, float]:
        import torch

        t0 = time.monotonic()
        audio = self._apply_silero_vad(pcm, fast_partial) if use_vad else pcm
        if audio.size < 2400:  # < 150ms of speech
            return "", language or "ko", (time.monotonic() - t0) * 1000.0

        # Chunk into <=28s windows if an utterance is unusually long
        max_samples = 16000 * 28
        windows = [audio[i:i + max_samples] for i in range(0, audio.size, max_samples)]
        texts: list[str] = []
        detected_lang = language or "ko"
        dev = next(self.torch_model.parameters()).device

        for win in windows:
            inputs = self.processor(
                win,
                sampling_rate=16000,
                return_tensors="pt",
                return_attention_mask=True,
            )
            input_features = inputs.input_features.to(device=dev, dtype=self.torch_dtype)
            attention_mask = inputs.attention_mask.to(device=dev) if hasattr(inputs, "attention_mask") else None

            gen_kwargs: dict = {
                "task": "transcribe",
                "num_beams": 1 if fast_partial else 3,
                "do_sample": False,
                "return_timestamps": False,
                "max_new_tokens": 128 if fast_partial else 224,
            }
            if attention_mask is not None:
                gen_kwargs["attention_mask"] = attention_mask
            if language:
                gen_kwargs["language"] = language
            if self.prompt_ids is not None and not fast_partial:
                gen_kwargs["prompt_ids"] = self.prompt_ids

            with torch.inference_mode():
                try:
                    predicted_ids = self.torch_model.generate(input_features, **gen_kwargs)
                except (ValueError, TypeError) as exc:
                    if "prompt_ids" in gen_kwargs:
                        log.warning("Disabling prompt_ids for torch Whisper (%s)", exc)
                        gen_kwargs.pop("prompt_ids", None)
                        self.prompt_ids = None
                        predicted_ids = self.torch_model.generate(input_features, **gen_kwargs)
                    else:
                        raise

            seq = predicted_ids[0].tolist()
            # Slice from <|startoftranscript|> so prompt_ids prefix never leaks into output text
            if self.sot_id is not None and self.sot_id in seq:
                sot_idx = seq.index(self.sot_id)
                if not language and sot_idx + 1 < len(seq):
                    lang_tok = self.processor.tokenizer.convert_ids_to_tokens(seq[sot_idx + 1])
                    if isinstance(lang_tok, str) and lang_tok.startswith("<|") and lang_tok.endswith("|>"):
                        code = lang_tok[2:-2]
                        if len(code) in (2, 3) and code.isalpha():
                            detected_lang = code
                seq = seq[sot_idx:]

            piece = self.processor.tokenizer.decode(seq, skip_special_tokens=True).strip()
            if piece:
                texts.append(piece)

        text = " ".join(texts).strip()
        elapsed_ms = (time.monotonic() - t0) * 1000.0
        if text in HALLUCINATION_FILTERS:
            text = ""
        return text, detected_lang, elapsed_ms

    def transcribe(
        self,
        pcm: np.ndarray,
        language: str | None = None,
        fast_partial: bool = False,
    ) -> tuple[str, str, float]:
        """Returns (text, detected_language, elapsed_ms)."""
        if not self.ready or pcm.size < 3200:  # < 200ms
            return "", language or "ko", 0.0

        lang_arg = None if (not language or language == "auto") else language

        with self._lock:
            if self.torch_model is not None:
                return self._transcribe_torch(pcm, language=lang_arg, fast_partial=fast_partial, use_vad=True)

            if self.model is None:
                return "", language or "ko", 0.0

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
