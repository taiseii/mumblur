"""Mic capture for mumbler.

Records 16 kHz mono float32 audio into an in-memory buffer between
start_recording() and stop_recording() calls. The real `sounddevice.InputStream`
is the default backend; tests inject a fake factory.
"""

from __future__ import annotations

import sys
import traceback
from typing import Callable, Protocol

import numpy as np

SAMPLE_RATE = 16000


class _Stream(Protocol):
    def start(self) -> None: ...
    def stop(self) -> None: ...
    def close(self) -> None: ...


StreamFactory = Callable[..., _Stream]


def _default_factory(**kwargs) -> _Stream:
    import sounddevice  # lazy import keeps tests independent of PortAudio
    return sounddevice.InputStream(**kwargs)


class AudioRecorder:
    """Owns the mic stream and the sample buffer for one recording cycle."""

    def __init__(self, stream_factory: StreamFactory = _default_factory) -> None:
        self._factory = stream_factory
        self._stream: _Stream | None = None
        self._chunks: list[np.ndarray] = []

    def start_recording(self) -> None:
        if self._stream is not None:
            raise RuntimeError("already recording")
        self._chunks = []
        self._stream = self._factory(
            callback=self._on_audio,
            samplerate=SAMPLE_RATE,
            channels=1,
            dtype="float32",
            blocksize=0,
        )
        self._stream.start()

    def stop_recording(self) -> np.ndarray:
        if self._stream is None:
            return np.zeros(0, dtype=np.float32)
        stream = self._stream
        self._stream = None
        try:
            stream.stop()
            stream.close()
        except Exception:
            print("[mumbler] audio stream stop failed:", file=sys.stderr)
            traceback.print_exc()
            return np.zeros(0, dtype=np.float32)
        if not self._chunks:
            return np.zeros(0, dtype=np.float32)
        return np.concatenate(self._chunks).astype(np.float32, copy=False)

    def abort_if_active(self) -> None:
        """Best-effort cleanup for shutdown paths. Never raises."""
        if self._stream is None:
            return
        try:
            self._stream.stop()
            self._stream.close()
        except Exception:
            pass
        finally:
            self._stream = None
            self._chunks = []

    def _on_audio(self, indata: np.ndarray, frames: int, time_info, status) -> None:
        # indata shape: (frames, channels). We requested mono, so flatten.
        self._chunks.append(indata[:, 0].copy())
