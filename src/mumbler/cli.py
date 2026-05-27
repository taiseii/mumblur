"""CLI entrypoint for mumbler.

`Runner` holds the locked state machine. `main()` parses args, constructs the
real collaborators, hands control to `hotkey.listen`, and aborts an active
recording on Ctrl-C.
"""

from __future__ import annotations

import argparse
import sys
import threading
import time
import traceback
from typing import Callable, Protocol

import numpy as np


# ----- Protocols (kept narrow so the Runner can accept fakes in tests) -----


class _RecorderLike(Protocol):
    def start_recording(self) -> None: ...
    def stop_recording(self) -> np.ndarray: ...
    def abort_if_active(self) -> None: ...


class _TranscriberLike(Protocol):
    def transcribe(self, samples: np.ndarray) -> str: ...


StartWorker = Callable[..., None]  # callable(fn, *args)


def _thread_worker(fn, *args) -> None:
    threading.Thread(target=fn, args=args, daemon=True).start()


# ----- Runner -----


class Runner:
    """Locked state machine. Transcribe + paste run on a worker thread."""

    IDLE = "idle"
    RECORDING = "recording"
    TRANSCRIBING = "transcribing"

    def __init__(
        self,
        recorder: _RecorderLike,
        transcriber: _TranscriberLike,
        paste_fn: Callable[[str], None],
        min_hold_ms: int = 200,
        clock: Callable[[], float] = time.monotonic,
        start_worker: StartWorker = _thread_worker,
    ) -> None:
        self._recorder = recorder
        self._transcriber = transcriber
        self._paste = paste_fn
        self._min_hold_ms = min_hold_ms
        self._clock = clock
        self._start_worker = start_worker
        self._lock = threading.Lock()
        self._state = self.IDLE
        self._press_t = 0.0

    @property
    def state(self) -> str:
        with self._lock:
            return self._state

    def on_press(self) -> None:
        with self._lock:
            if self._state != self.IDLE:
                print(
                    f"[mumbler] press ignored (state={self._state})",
                    file=sys.stderr,
                )
                return
            self._state = self.RECORDING
            self._press_t = self._clock()
        self._recorder.start_recording()

    def on_release(self) -> None:
        with self._lock:
            if self._state != self.RECORDING:
                return
        samples = self._recorder.stop_recording()
        held_ms = (self._clock() - self._press_t) * 1000
        if held_ms < self._min_hold_ms:
            with self._lock:
                self._state = self.IDLE
            return
        with self._lock:
            self._state = self.TRANSCRIBING
        self._start_worker(self._do_work, samples)

    def shutdown(self) -> None:
        """Stop any active recording and return to IDLE. Safe to call twice."""
        try:
            self._recorder.abort_if_active()
        except Exception:
            pass
        with self._lock:
            self._state = self.IDLE

    def _do_work(self, samples: np.ndarray) -> None:
        try:
            try:
                text = self._transcriber.transcribe(samples)
            except Exception:
                print("[mumbler] transcription failed:", file=sys.stderr)
                traceback.print_exc()
                return
            if not text.strip():
                return
            try:
                self._paste(text)
            except Exception:
                print("[mumbler] paste failed:", file=sys.stderr)
                traceback.print_exc()
        finally:
            with self._lock:
                self._state = self.IDLE


# ----- main() -----


def _parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="mumbler", description=__doc__)
    p.add_argument("--hotkey", default="alt_r",
                   help="pynput.keyboard.Key name (default: alt_r = Right Option)")
    p.add_argument("--model", default="large-v3-turbo-q5_0",
                   help="pywhispercpp model name or path to .bin")
    p.add_argument("--language", default="auto",
                   help="Whisper language code, or 'auto' (default)")
    p.add_argument("--min-hold-ms", type=int, default=200,
                   help="Discard presses shorter than this (default: 200)")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    from pynput import keyboard

    from mumbler.audio import AudioRecorder
    from mumbler.hotkey import listen
    from mumbler.paste import paste as default_paste
    from mumbler.transcribe import Transcriber

    args = _parse_args(argv if argv is not None else sys.argv[1:])

    try:
        target = getattr(keyboard.Key, args.hotkey)
    except AttributeError:
        print(f"[mumbler] unknown hotkey: {args.hotkey!r}", file=sys.stderr)
        return 2

    # On macOS, pynput's listener silently fails (only prints to stderr) when
    # Accessibility isn't granted. Detect this upfront so the user gets a clean
    # actionable error instead of a half-running daemon that never receives keys.
    if getattr(keyboard.Listener, "IS_TRUSTED", True) is False:
        print(
            "[mumbler] missing macOS Accessibility permission.\n"
            "  Grant it in System Settings → Privacy & Security → Accessibility\n"
            "  for the terminal app running mumbler, then fully quit and relaunch\n"
            "  the terminal (the permission is captured at launch).",
            file=sys.stderr,
        )
        return 3

    print(f"[mumbler] loading model {args.model!r}…", file=sys.stderr)
    transcriber = Transcriber(args.model, language=args.language)
    recorder = AudioRecorder()
    runner = Runner(
        recorder=recorder,
        transcriber=transcriber,
        paste_fn=default_paste,
        min_hold_ms=args.min_hold_ms,
    )
    print(
        f"[mumbler] model loaded; hold {args.hotkey} to dictate. Ctrl-C to quit.",
        file=sys.stderr,
    )

    try:
        listen(runner.on_press, runner.on_release, target_key=target)
    except KeyboardInterrupt:
        runner.shutdown()
        print("[mumbler] bye", file=sys.stderr)
        return 0
    except Exception as e:
        runner.shutdown()
        msg = str(e).lower()
        if "accessibility" in msg or "trusted" in msg or "not authorized" in msg:
            print(
                "[mumbler] missing macOS Accessibility permission.\n"
                "  Grant it in System Settings → Privacy & Security → Accessibility\n"
                "  for the terminal app running mumbler, then relaunch.",
                file=sys.stderr,
            )
            return 3
        if "input device" in msg or "portaudio" in msg or "microphone" in msg:
            print(
                "[mumbler] microphone unavailable. Grant Microphone permission\n"
                "  in System Settings → Privacy & Security → Microphone, then relaunch.",
                file=sys.stderr,
            )
            return 3
        raise
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
