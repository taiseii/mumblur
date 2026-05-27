"""Tests for mumbler.audio.AudioRecorder."""

from __future__ import annotations

import numpy as np
import pytest

from mumbler.audio import AudioRecorder, SAMPLE_RATE


class FakeStream:
    """Stand-in for sounddevice.InputStream that lets the test push frames."""

    def __init__(self, callback, samplerate, channels, dtype, blocksize):
        self.callback = callback
        self.samplerate = samplerate
        self.channels = channels
        self.dtype = dtype
        self.blocksize = blocksize
        self.started = False
        self.stopped = False
        self.closed = False
        self.stop_raises: Exception | None = None

    def start(self):
        self.started = True

    def stop(self):
        self.stopped = True
        if self.stop_raises is not None:
            raise self.stop_raises

    def close(self):
        self.closed = True

    def push(self, samples: np.ndarray):
        block = samples.reshape(-1, 1)  # mono → (frames, channels)
        self.callback(block, len(block), None, None)


def make_factory():
    class Ref:
        stream: FakeStream | None = None

    ref = Ref()

    def factory(**kwargs):
        ref.stream = FakeStream(**kwargs)
        return ref.stream

    return factory, ref


def test_records_at_16khz_mono_float32():
    factory, ref = make_factory()
    rec = AudioRecorder(stream_factory=factory)

    rec.start_recording()
    assert ref.stream is not None
    assert ref.stream.samplerate == SAMPLE_RATE == 16000
    assert ref.stream.channels == 1
    assert ref.stream.dtype == "float32"
    assert ref.stream.started is True


def test_stop_returns_concatenated_buffer():
    factory, ref = make_factory()
    rec = AudioRecorder(stream_factory=factory)

    rec.start_recording()
    ref.stream.push(np.array([0.1, 0.2, 0.3], dtype=np.float32))
    ref.stream.push(np.array([0.4, 0.5], dtype=np.float32))
    samples = rec.stop_recording()

    np.testing.assert_array_equal(
        samples, np.array([0.1, 0.2, 0.3, 0.4, 0.5], dtype=np.float32)
    )
    assert samples.dtype == np.float32
    assert ref.stream.stopped is True
    assert ref.stream.closed is True


def test_stop_without_start_returns_empty():
    factory, _ = make_factory()
    rec = AudioRecorder(stream_factory=factory)
    samples = rec.stop_recording()
    assert isinstance(samples, np.ndarray)
    assert samples.shape == (0,)
    assert samples.dtype == np.float32


def test_start_then_start_raises():
    factory, _ = make_factory()
    rec = AudioRecorder(stream_factory=factory)
    rec.start_recording()
    with pytest.raises(RuntimeError, match="already recording"):
        rec.start_recording()


def test_second_cycle_resets_buffer():
    factory, ref = make_factory()
    rec = AudioRecorder(stream_factory=factory)

    rec.start_recording()
    ref.stream.push(np.array([1.0, 2.0], dtype=np.float32))
    first = rec.stop_recording()

    rec.start_recording()
    ref.stream.push(np.array([9.0], dtype=np.float32))
    second = rec.stop_recording()

    np.testing.assert_array_equal(first, np.array([1.0, 2.0], dtype=np.float32))
    np.testing.assert_array_equal(second, np.array([9.0], dtype=np.float32))


def test_stop_swallows_stream_errors_and_returns_empty():
    """Audio device unplugged mid-recording: stop_recording must not raise."""
    factory, ref = make_factory()
    rec = AudioRecorder(stream_factory=factory)
    rec.start_recording()
    ref.stream.push(np.array([0.1], dtype=np.float32))
    ref.stream.stop_raises = OSError("device unplugged")

    samples = rec.stop_recording()

    assert samples.shape == (0,)
    assert samples.dtype == np.float32
    rec.start_recording()
    rec.stop_recording()
