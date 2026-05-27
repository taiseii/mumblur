"""Tests for mumbler.cli — wiring between the modules.

start_worker is injected so the test runs synchronously; the real cli.main()
uses threading.Thread.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field

import numpy as np

from mumbler import cli


@dataclass
class FakeRecorder:
    started: int = 0
    stopped: int = 0
    aborted: int = 0
    samples_to_return: np.ndarray = field(
        default_factory=lambda: np.array([0.1, 0.2], dtype=np.float32)
    )

    def start_recording(self) -> None:
        self.started += 1

    def stop_recording(self) -> np.ndarray:
        self.stopped += 1
        return self.samples_to_return

    def abort_if_active(self) -> None:
        self.aborted += 1


@dataclass
class FakeTranscriber:
    text: str = "the cat sat on the mat"
    calls: list[np.ndarray] = field(default_factory=list)

    def transcribe(self, samples: np.ndarray) -> str:
        self.calls.append(samples)
        return self.text


@dataclass
class PasteSpy:
    calls: list[str] = field(default_factory=list)
    raise_on_call: bool = False

    def __call__(self, text: str) -> None:
        self.calls.append(text)
        if self.raise_on_call:
            raise RuntimeError("paste exploded")


def sync_worker(fn, *args):
    """Run the worker callable inline so the test stays deterministic."""
    fn(*args)


def make_runner(**overrides):
    defaults = dict(
        recorder=FakeRecorder(),
        transcriber=FakeTranscriber(),
        paste_fn=PasteSpy(),
        min_hold_ms=0,
        clock=time.monotonic,
        start_worker=sync_worker,
    )
    defaults.update(overrides)
    return cli.Runner(**defaults), defaults


def test_full_press_release_cycle_records_transcribes_pastes():
    paste = PasteSpy()
    tr = FakeTranscriber(text="hello world")
    rec = FakeRecorder()
    runner, _ = make_runner(recorder=rec, transcriber=tr, paste_fn=paste)

    runner.on_press()
    runner.on_release()

    assert rec.started == 1
    assert rec.stopped == 1
    assert len(tr.calls) == 1
    assert paste.calls == ["hello world"]
    assert runner.state == cli.Runner.IDLE


def test_press_shorter_than_min_hold_discards():
    paste = PasteSpy()
    tr = FakeTranscriber()
    rec = FakeRecorder()
    fake_now = [0.0]
    runner, _ = make_runner(
        recorder=rec,
        transcriber=tr,
        paste_fn=paste,
        min_hold_ms=200,
        clock=lambda: fake_now[0],
    )

    fake_now[0] = 0.0
    runner.on_press()
    fake_now[0] = 0.05  # 50 ms
    runner.on_release()

    assert rec.started == 1
    assert rec.stopped == 1
    assert tr.calls == []
    assert paste.calls == []
    assert runner.state == cli.Runner.IDLE


def test_empty_transcript_does_not_paste():
    paste = PasteSpy()
    tr = FakeTranscriber(text="   ")
    runner, _ = make_runner(transcriber=tr, paste_fn=paste)

    runner.on_press()
    runner.on_release()

    assert tr.calls != []
    assert paste.calls == []
    assert runner.state == cli.Runner.IDLE


def test_press_during_transcription_is_ignored():
    """Worker is deferred so the test can observe TRANSCRIBING state before it runs."""
    paste = PasteSpy()
    rec = FakeRecorder()
    tr = FakeTranscriber(text="result")

    pending: list[tuple] = []

    def deferred_worker(fn, *args):
        pending.append((fn, args))  # capture; don't execute yet

    runner, _ = make_runner(
        recorder=rec,
        transcriber=tr,
        paste_fn=paste,
        start_worker=deferred_worker,
    )

    runner.on_press()
    runner.on_release()  # schedules worker but does not run it

    assert len(pending) == 1
    assert runner.state == cli.Runner.TRANSCRIBING

    # New press while worker is still pending is ignored.
    runner.on_press()
    assert rec.started == 1  # not 2
    assert runner.state == cli.Runner.TRANSCRIBING

    # Now actually run the worker; state returns to IDLE and paste fires.
    fn, args = pending[0]
    fn(*args)
    assert runner.state == cli.Runner.IDLE
    assert paste.calls == ["result"]


def test_transcribe_exception_is_caught_and_loop_continues():
    rec = FakeRecorder()
    paste = PasteSpy()

    class BoomTranscriber:
        def __init__(self):
            self.calls = 0

        def transcribe(self, samples):
            self.calls += 1
            raise RuntimeError("boom")

    tr = BoomTranscriber()
    runner, _ = make_runner(recorder=rec, transcriber=tr, paste_fn=paste)

    runner.on_press()
    runner.on_release()  # must NOT raise

    assert tr.calls == 1
    assert paste.calls == []
    assert runner.state == cli.Runner.IDLE

    # And a second cycle still works.
    runner.on_press()
    runner.on_release()
    assert tr.calls == 2


def test_paste_exception_is_caught_and_loop_continues():
    rec = FakeRecorder()
    tr = FakeTranscriber(text="x")
    paste = PasteSpy(raise_on_call=True)
    runner, _ = make_runner(recorder=rec, transcriber=tr, paste_fn=paste)

    runner.on_press()
    runner.on_release()  # paste raises inside the worker; must NOT propagate

    assert paste.calls == ["x"]
    assert runner.state == cli.Runner.IDLE

    # Recover on next cycle.
    paste.raise_on_call = False
    runner.on_press()
    runner.on_release()
    assert paste.calls == ["x", "x"]


def test_shutdown_aborts_active_recording():
    rec = FakeRecorder()
    runner, _ = make_runner(recorder=rec)

    runner.on_press()
    assert runner.state == cli.Runner.RECORDING
    runner.shutdown()

    assert rec.aborted == 1
    assert runner.state == cli.Runner.IDLE
