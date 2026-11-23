"""Decodes Even Realities G2 raw 16kHz LC3 microphone frames (0x6402) to float32 PCM.

Supports native ARM64/x86_64 Google `liblc3.so.1` via ctypes (zero pip wheel needed on DGX Spark aarch64),
with automatic fallback to `lc3py` if installed.
"""
from __future__ import annotations

import ctypes
import ctypes.util
import logging
import os
from pathlib import Path

import numpy as np

log = logging.getLogger("g2.audio")

SAMPLE_RATE = 16000
FRAME_DURATION_US = 10000  # 10ms = 160 samples per frame
LC3_FRAME_BYTES = 40       # G2 streams 32kbps mono 16kHz LC3 -> 40 bytes per 10ms frame
LC3_PCM_FORMAT_FLOAT = 3   # enum lc3_pcm_format::LC3_PCM_FORMAT_FLOAT in Google liblc3


def load_liblc3() -> ctypes.CDLL | None:
    """Finds and loads native Google liblc3 shared library across Linux aarch64/x86_64 and macOS."""
    here = Path(__file__).resolve().parent
    candidates = [
        os.environ.get("G2_LIBLC3_PATH", ""),
        str(here / "liblc3.so"),
        str(here / "liblc3.so.1"),
        ctypes.util.find_library("lc3") or "",
        "liblc3.so.1",
        "liblc3.so",
        "/usr/lib/aarch64-linux-gnu/liblc3.so.1",
        "/usr/lib/aarch64-linux-gnu/liblc3.so",
        "/usr/lib/x86_64-linux-gnu/liblc3.so.1",
        "/usr/local/lib/liblc3.so.1",
        "/opt/homebrew/lib/liblc3.dylib",
    ]
    for path in candidates:
        if not path:
            continue
        try:
            lib = ctypes.CDLL(path)
            if hasattr(lib, "lc3_setup_decoder") and hasattr(lib, "lc3_decode"):
                return lib
        except OSError:
            continue
    return None


class _CtypesLibLC3Decoder:
    def __init__(self, lib: ctypes.CDLL, dt_us: int = FRAME_DURATION_US, sr_hz: int = SAMPLE_RATE) -> None:
        lib.lc3_decoder_size.argtypes = [ctypes.c_int, ctypes.c_int]
        lib.lc3_decoder_size.restype = ctypes.c_uint
        lib.lc3_setup_decoder.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        lib.lc3_setup_decoder.restype = ctypes.c_void_p
        lib.lc3_decode.argtypes = [
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        lib.lc3_decode.restype = ctypes.c_int

        mem_size = int(lib.lc3_decoder_size(dt_us, sr_hz))
        if mem_size <= 0:
            raise RuntimeError(f"Invalid liblc3 params dt={dt_us}, sr={sr_hz}")
        self._lib = lib
        self._mem = ctypes.create_string_buffer(mem_size)
        self._handle = lib.lc3_setup_decoder(dt_us, sr_hz, 0, ctypes.byref(self._mem))
        if not self._handle:
            raise RuntimeError("lc3_setup_decoder returned NULL")
        self._samples_per_frame = (sr_hz * dt_us) // 1_000_000

    def decode_frame(self, frame: bytes) -> np.ndarray:
        out = np.empty(self._samples_per_frame, dtype=np.float32)
        self._lib.lc3_decode(
            self._handle,
            frame,
            len(frame),
            LC3_PCM_FORMAT_FLOAT,
            out.ctypes.data_as(ctypes.c_void_p),
            1,
        )
        return out


class G2AudioDecoder:
    """Streaming decoder accepting either G2 raw LC3 frames (40B/10ms) or raw PCM16 LE."""

    def __init__(self, codec: str = "lc3_16k") -> None:
        self.codec = codec
        self._remainder = bytearray()
        self._ctypes_dec: _CtypesLibLC3Decoder | None = None
        self._lc3py_dec = None
        if codec == "lc3_16k":
            self._init_lc3()

    def _init_lc3(self) -> None:
        lib = load_liblc3()
        if lib is not None:
            self._ctypes_dec = _CtypesLibLC3Decoder(lib, FRAME_DURATION_US, SAMPLE_RATE)
            self._lc3py_dec = None
            return
        try:
            import lc3  # optional lc3py fallback on x86_64/macOS
            self._lc3py_dec = lc3.Decoder(FRAME_DURATION_US, SAMPLE_RATE)
            self._ctypes_dec = None
        except Exception as exc:
            log.warning("Neither liblc3.so.1 nor lc3py available (%s)", exc)

    def reset(self, codec: str | None = None) -> None:
        if codec:
            self.codec = codec
        self._remainder.clear()
        if self.codec == "lc3_16k":
            self._init_lc3()

    def decode(self, chunk: bytes) -> np.ndarray:
        """Returns 1-D float32 numpy array normalized to [-1.0, 1.0] at 16kHz."""
        if not chunk:
            return np.zeros(0, dtype=np.float32)

        if self.codec == "pcm16_16k":
            self._remainder.extend(chunk)
            usable = (len(self._remainder) // 2) * 2
            if usable == 0:
                return np.zeros(0, dtype=np.float32)
            raw = bytes(self._remainder[:usable])
            del self._remainder[:usable]
            return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0

        if self._ctypes_dec is None and self._lc3py_dec is None:
            self._init_lc3()
        if self._ctypes_dec is None and self._lc3py_dec is None:
            raise RuntimeError("liblc3 not found on Spark node. Run: sudo apt-get install -y liblc3-1")

        self._remainder.extend(chunk)
        n_frames = len(self._remainder) // LC3_FRAME_BYTES
        if n_frames == 0:
            return np.zeros(0, dtype=np.float32)

        out_chunks: list[np.ndarray] = []
        for idx in range(n_frames):
            start = idx * LC3_FRAME_BYTES
            frame = bytes(self._remainder[start : start + LC3_FRAME_BYTES])
            if self._ctypes_dec is not None:
                out_chunks.append(self._ctypes_dec.decode_frame(frame))
            else:
                pcm_bytes = self._lc3py_dec.decode(frame, bit_depth=16)
                out_chunks.append(np.frombuffer(pcm_bytes, dtype="<i2").astype(np.float32) / 32768.0)

        del self._remainder[: n_frames * LC3_FRAME_BYTES]
        return np.concatenate(out_chunks) if out_chunks else np.zeros(0, dtype=np.float32)


def chunk_rms(pcm: np.ndarray) -> float:
    if pcm.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(pcm))))
