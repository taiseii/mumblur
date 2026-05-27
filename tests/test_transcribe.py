"""Tests for mumbler.transcribe.Transcriber."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from mumbler.transcribe import Transcriber


class FakeSegment:
    def __init__(self, text: str):
        self.text = text


class FakeModel:
    def __init__(self, model_path_or_name: str, **kwargs):
        self.model_path_or_name = model_path_or_name
        self.kwargs = kwargs
        self.transcribe_calls: list[np.ndarray] = []
        self.next_segments: list[FakeSegment] = []

    def transcribe(self, samples, **kwargs):
        self.transcribe_calls.append(samples)
        self.kwargs.update(kwargs)
        return self.next_segments


def test_transcriber_loads_named_model_on_construction():
    holder = {}

    def factory(name, **kw):
        m = FakeModel(name, **kw)
        holder["model"] = m
        return m

    t = Transcriber("large-v3-turbo-q5_0", n_threads=8, model_factory=factory)

    assert holder["model"].model_path_or_name == "large-v3-turbo-q5_0"
    assert holder["model"].kwargs["n_threads"] == 8


def test_transcribe_joins_segments_and_strips():
    fake = FakeModel("x")
    fake.next_segments = [FakeSegment("  hello "), FakeSegment("world  ")]
    t = Transcriber("x", model_factory=lambda name, **kw: fake)

    samples = np.array([0.0, 0.1, 0.2], dtype=np.float32)
    result = t.transcribe(samples)

    assert result == "hello world"
    assert len(fake.transcribe_calls) == 1
    np.testing.assert_array_equal(fake.transcribe_calls[0], samples)


def test_transcribe_empty_samples_returns_empty_without_calling_model():
    fake = FakeModel("x")
    t = Transcriber("x", model_factory=lambda name, **kw: fake)

    result = t.transcribe(np.zeros(0, dtype=np.float32))

    assert result == ""
    assert fake.transcribe_calls == []


def test_transcribe_passes_language_kwarg():
    fake = FakeModel("x")
    t = Transcriber("x", language="en", model_factory=lambda name, **kw: fake)

    t.transcribe(np.array([0.1], dtype=np.float32))

    assert fake.kwargs.get("language") == "en"


# ----- Integration test (slow, loads the real model) -----


@pytest.mark.slow
def test_integration_transcribes_hello_world_fixture():
    fixture = Path(__file__).parent / "fixtures" / "hello_world.wav"
    samples, sr = sf.read(fixture, dtype="float32")
    assert sr == 16000, f"fixture must be 16kHz, got {sr}"
    if samples.ndim > 1:
        samples = samples.mean(axis=1).astype(np.float32)

    t = Transcriber("large-v3-turbo-q5_0")
    result = t.transcribe(samples).lower()

    assert "hello" in result and "world" in result, f"got: {result!r}"
