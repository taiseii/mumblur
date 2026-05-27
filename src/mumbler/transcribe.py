"""Whisper transcription via pywhispercpp.

Loads the model once at construction and reuses it for every call. Callers
pass raw float32 mono samples at 16 kHz; we return a plain string.
"""

from __future__ import annotations

from typing import Callable, Protocol

import numpy as np


class _Model(Protocol):
    def transcribe(self, samples, **kwargs): ...


def _default_factory(model: str, **kwargs) -> _Model:
    from pywhispercpp.model import Model
    return Model(model, **kwargs)


ModelFactory = Callable[..., _Model]


class Transcriber:
    """Wrapper around a long-lived pywhispercpp Model."""

    def __init__(
        self,
        model: str = "large-v3-turbo-q5_0",
        *,
        n_threads: int = 8,
        language: str = "auto",
        model_factory: ModelFactory = _default_factory,
    ) -> None:
        self._language = language
        self._model = model_factory(
            model,
            n_threads=n_threads,
            print_realtime=False,
            print_progress=False,
        )

    def transcribe(self, samples: np.ndarray) -> str:
        if samples.size == 0:
            return ""
        segments = self._model.transcribe(samples, language=self._language)
        return "".join(seg.text for seg in segments).strip()
