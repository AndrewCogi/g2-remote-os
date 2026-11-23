"""Decodes Even Realities G2 raw 16kHz LC3 microphone frames (0x6402) to float32 PCM."""
from __future__ import annotations

import logging
import numpy as np

log = logging.getLogger("g2.audio")

SAMPLE_RATE = 16000
FRAME_DURATION_US = 10000  # 10ms = 160 samples per frame
LC3_FRAME_BYTES = 40       # G2 streams 32kbps mono 16kHz LC3 -> 40 bytes per 10ms frame


class G2AudioDecoder:
    """Streaming decoder accepting either G2 raw LC3 frames (40B/10ms) or raw PCM16 LE."""

    def __init__(self, codec: str = "lc3_16k") -> None:
        self.codec = codec
        self._remainder = bytearray()
        self._lc3 = None
        if codec == "lc3_16k":
            try:
                import lc3  # lc3py exposes module name `lc3`
                self._lc3 = lc3.Decoder(FRAME_DURATION_US, SAMPLE_RATE)
            except Exception as exc:
                log.warning("lc3py unavailable (%s); falling back to pcm16 if raw PCM is sent", exc)

    def reset(self, codec: str | None = None) -> None:
        if codec:
            self.codec = codec
        self._remainder.clear()
        if self.codec == "lc3_16k" and self._lc3 is None:
            try:
                import lc3
                self._lc3 = lc3.Decoder(FRAME_DURATION_US, SAMPLE_RATE)
            except Exception:
                pass

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
            pcm = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
            return pcm

        # Default: G2 raw LC3 16kHz (40 bytes per 10ms frame, 5 frames = 200B per BLE packet)
        if self._lc3 is None:
            raise RuntimeError("lc3py is not installed on this Spark node. Run bridge/install_spark.sh.")

        self._remainder.extend(chunk)
        n_frames = len(self._remainder) // LC3_FRAME_BYTES
        if n_frames == 0:
            return np.zeros(0, dtype=np.float32)

        out_chunks: list[np.ndarray] = []
        for idx in range(n_frames):
            start = idx * LC3_FRAME_BYTES
            frame = bytes(self._remainder[start : start + LC3_FRAME_BYTES])
            pcm_bytes = self._lc3.decode(frame, bit_depth=16)
            samples = np.frombuffer(pcm_bytes, dtype="<i2").astype(np.float32) / 32768.0
            out_chunks.append(samples)

        del self._remainder[: n_frames * LC3_FRAME_BYTES]
        return np.concatenate(out_chunks) if out_chunks else np.zeros(0, dtype=np.float32)


def chunk_rms(pcm: np.ndarray) -> float:
    if pcm.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(pcm))))
