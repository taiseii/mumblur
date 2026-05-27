# Push-to-Talk Local Dictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `mumbler` MVP from spec `docs/superpowers/specs/2026-05-27-push-to-talk-dictation-design.md` — a local CLI that records audio while a hotkey is held, transcribes it with whisper.cpp via `pywhispercpp`, and pastes the result at the cursor.

**Architecture:** Single Python process. `Transcriber` is constructed once at startup (loads `large-v3-turbo-q5_1` into Metal). `pynput` listens for Right Option globally; on press, `sounddevice` records a 16 kHz mono float32 buffer; on release, the buffer is handed to `Transcriber.transcribe()` and the result is pasted via `pbcopy` + ⌘V. Five small modules with narrow contracts so each one is independently testable.

**Tech Stack:** Python 3.12, `pywhispercpp`, `sounddevice`, `pynput`, `numpy`, `pytest`. macOS Apple Silicon only.

---

## Pre-flight

- [ ] **Confirm working directory**

Run: `pwd`
Expected: `/Users/taiseiigresb/Documents/.projects/mumbler`

- [ ] **Confirm spec exists**

Run: `ls docs/superpowers/specs/2026-05-27-push-to-talk-dictation-design.md`
Expected: file is listed, no error.

- [ ] **Confirm Python is 3.12**

Run: `cat .python-version`
Expected: `3.12` (or `3.12.x`)

---

## Task 1: Project scaffolding & dependencies

**Why first:** Every later task installs into this layout. Set it once.

**Files:**
- Create: `src/mumbler/__init__.py`
- Create: `tests/__init__.py`
- Modify: `pyproject.toml`
- Modify: `.gitignore`
- Delete: `main.py` (the `uv init` stub)
- Delete: `get_started.py` (the Modal example)

- [ ] **Step 1: Update `pyproject.toml`**

Replace the entire file with:

```toml
[project]
name = "mumbler"
version = "0.1.0"
description = "Local push-to-talk dictation for macOS using whisper.cpp"
readme = "README.md"
requires-python = ">=3.12"
dependencies = [
    "numpy>=2.0",
    "sounddevice>=0.5",
    "pynput>=1.7",
    "pywhispercpp>=1.3",
]

[project.scripts]
mumbler = "mumbler.cli:main"

[dependency-groups]
dev = [
    "pytest>=8.0",
    "soundfile>=0.12",
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/mumbler"]

[tool.pytest.ini_options]
testpaths = ["tests"]
markers = [
    "slow: marks tests that load the Whisper model (deselect with -m 'not slow')",
]
addopts = "-m 'not slow'"
```

Note: `modal` is dropped. `soundfile` is dev-only — needed by the integration test to read the fixture WAV; the runtime never touches WAV files.

- [ ] **Step 2: Update `.gitignore`**

Append (do not replace) these lines to `.gitignore`:

```
# Models (large binary files)
models/
*.bin

# Test artifacts
.pytest_cache/
__pycache__/
*.pyc
```

- [ ] **Step 3: Delete stub files and create package skeleton**

Run:
```bash
rm -f main.py get_started.py
mkdir -p src/mumbler tests/fixtures
touch src/mumbler/__init__.py tests/__init__.py
```

- [ ] **Step 4: Write package metadata**

Write `src/mumbler/__init__.py`:
```python
"""Mumbler — local push-to-talk dictation."""

__version__ = "0.1.0"
```

- [ ] **Step 5: Re-sync the venv**

Run: `uv sync --all-groups`
Expected: completes successfully; resolves and installs the new deps (this will take a minute — `pywhispercpp` builds against bundled whisper.cpp).

- [ ] **Step 6: Smoke-test the install**

Run: `uv run python -c "import mumbler; import pywhispercpp; import sounddevice; import pynput; import numpy; print('ok')"`
Expected: `ok` printed, no ImportError.

- [ ] **Step 7: Commit**

```bash
git add pyproject.toml .gitignore src/ tests/
git commit -m "chore: scaffold src/mumbler package and dev dependencies"
```

(No `git rm` needed — `main.py` and `get_started.py` were never committed, only deleted from the working tree.)

---

## Task 2: `audio.py` — mic capture with a fake-injectable stream

**Files:**
- Create: `src/mumbler/audio.py`
- Create: `tests/test_audio.py`

The module exposes an `AudioRecorder` class so tests can inject a fake `InputStream` factory. Default factory uses `sounddevice.InputStream`.

- [ ] **Step 1: Write the failing test**

Write `tests/test_audio.py`:

```python
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

    def start(self):
        self.started = True

    def stop(self):
        self.stopped = True

    def close(self):
        self.closed = True

    def push(self, samples: np.ndarray):
        """Simulate PortAudio delivering a block of frames."""
        block = samples.reshape(-1, 1)  # mono → (frames, channels)
        self.callback(block, len(block), None, None)


def make_factory():
    """Returns (factory, ref) where ref.stream is set when factory is called."""

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
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/test_audio.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mumbler.audio'`

- [ ] **Step 3: Implement `audio.py`**

Write `src/mumbler/audio.py`:

```python
"""Mic capture for mumbler.

Records 16 kHz mono float32 audio into an in-memory buffer between
start_recording() and stop_recording() calls. The real `sounddevice.InputStream`
is the default backend; tests inject a fake factory.
"""

from __future__ import annotations

from typing import Callable, Protocol

import numpy as np

SAMPLE_RATE = 16000


class _Stream(Protocol):
    def start(self) -> None: ...
    def stop(self) -> None: ...
    def close(self) -> None: ...


StreamFactory = Callable[..., _Stream]


def _default_factory(**kwargs) -> _Stream:
    import sounddevice  # imported lazily so tests don't need PortAudio
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
        self._stream.stop()
        self._stream.close()
        self._stream = None
        if not self._chunks:
            return np.zeros(0, dtype=np.float32)
        return np.concatenate(self._chunks).astype(np.float32, copy=False)

    def _on_audio(self, indata: np.ndarray, frames: int, time_info, status) -> None:
        # indata shape: (frames, channels). We requested mono, so flatten.
        self._chunks.append(indata[:, 0].copy())
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_audio.py -v`
Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/mumbler/audio.py tests/test_audio.py
git commit -m "feat(audio): AudioRecorder with injectable stream factory"
```

---

## Task 3: `paste.py` — clipboard write + ⌘V

**Files:**
- Create: `src/mumbler/paste.py`
- Create: `tests/test_paste.py`

The module exposes a `paste(text)` function. Clipboard side is real (uses `pbcopy`/`pbpaste`). Keystroke side is injected so tests can assert without an active app.

- [ ] **Step 1: Write the failing test**

Write `tests/test_paste.py`:

```python
"""Tests for mumbler.paste."""

from __future__ import annotations

import subprocess

from mumbler.paste import paste


class FakeKeystroke:
    def __init__(self):
        self.calls = []

    def __call__(self):
        self.calls.append("cmd+v")


def read_pasteboard() -> str:
    return subprocess.run(
        ["pbpaste"], capture_output=True, text=True, check=True
    ).stdout


def test_paste_writes_to_pasteboard_and_synthesizes_cmd_v():
    keystroke = FakeKeystroke()
    paste("hello mumbler", send_cmd_v=keystroke)

    assert read_pasteboard() == "hello mumbler"
    assert keystroke.calls == ["cmd+v"]


def test_paste_empty_string_is_noop():
    keystroke = FakeKeystroke()
    # Seed pasteboard with a sentinel.
    subprocess.run(["pbcopy"], input="sentinel", text=True, check=True)
    paste("", send_cmd_v=keystroke)
    assert read_pasteboard() == "sentinel"  # untouched
    assert keystroke.calls == []  # no keystroke


def test_paste_whitespace_only_is_noop():
    keystroke = FakeKeystroke()
    subprocess.run(["pbcopy"], input="sentinel2", text=True, check=True)
    paste("   \n\t  ", send_cmd_v=keystroke)
    assert read_pasteboard() == "sentinel2"
    assert keystroke.calls == []
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/test_paste.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mumbler.paste'`

- [ ] **Step 3: Implement `paste.py`**

Write `src/mumbler/paste.py`:

```python
"""Paste a string at the cursor in the active macOS app.

Writes the text to the pasteboard via `pbcopy`, then synthesizes a Cmd+V
keystroke via `pynput`. Empty / whitespace strings are skipped entirely.
"""

from __future__ import annotations

import subprocess
from typing import Callable


def _default_cmd_v() -> None:
    # Lazy import: pynput pulls in macOS Quartz bindings.
    from pynput.keyboard import Controller, Key

    kb = Controller()
    with kb.pressed(Key.cmd):
        kb.press("v")
        kb.release("v")


def paste(text: str, send_cmd_v: Callable[[], None] = _default_cmd_v) -> None:
    if not text or not text.strip():
        return

    subprocess.run(
        ["pbcopy"],
        input=text,
        text=True,
        check=True,
    )
    send_cmd_v()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_paste.py -v`
Expected: all 3 tests PASS.

Note: this test mutates the system pasteboard. It will overwrite whatever the developer has copied. The fake `FakeKeystroke` prevents the actual ⌘V from firing, so it won't paste into anything.

- [ ] **Step 5: Commit**

```bash
git add src/mumbler/paste.py tests/test_paste.py
git commit -m "feat(paste): clipboard write + injectable cmd+v synthesis"
```

---

## Task 4: `transcribe.py` — pywhispercpp wrapper

**Files:**
- Create: `src/mumbler/transcribe.py`
- Create: `tests/test_transcribe.py`
- Create: `tests/fixtures/hello_world.wav` (script-generated, see Step 1)
- Create: `scripts/make_test_fixture.py`

The `Transcriber` is a thin class around `pywhispercpp.model.Model`. We test it two ways: a fast unit test that injects a fake model, plus a `@pytest.mark.slow` integration test that loads the real model and transcribes a fixture.

- [ ] **Step 1: Generate the test fixture**

We don't want to commit a recording of the developer, and we don't want the test depending on a separate TTS install. Synthesize a short clip by using macOS `say`.

Create `scripts/make_test_fixture.py`:

```python
"""Generate tests/fixtures/hello_world.wav using macOS `say`.

Run once; the resulting WAV is committed so the test fixture is reproducible.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

FIXTURE = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "hello_world.wav"


def main() -> int:
    if shutil.which("say") is None:
        print("`say` not found; this script requires macOS.", file=sys.stderr)
        return 1
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    aiff = FIXTURE.with_suffix(".aiff")
    subprocess.run(
        ["say", "-v", "Samantha", "-o", str(aiff), "hello world"],
        check=True,
    )
    # Convert to 16 kHz mono PCM WAV via afconvert (ships with macOS).
    subprocess.run(
        [
            "afconvert",
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            str(aiff),
            str(FIXTURE),
        ],
        check=True,
    )
    aiff.unlink()
    print(f"wrote {FIXTURE} ({FIXTURE.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Run: `uv run python scripts/make_test_fixture.py`
Expected: prints `wrote .../hello_world.wav (...)`. File is < 100 KB.

Verify: `ls -la tests/fixtures/hello_world.wav`

- [ ] **Step 2: Write the failing test**

Write `tests/test_transcribe.py`:

```python
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
    fake_holder = {}

    def factory(name, **kw):
        m = FakeModel(name, **kw)
        fake_holder["model"] = m
        return m

    t = Transcriber("large-v3-turbo-q5_1", n_threads=8, model_factory=factory)

    assert fake_holder["model"].model_path_or_name == "large-v3-turbo-q5_1"
    assert fake_holder["model"].kwargs["n_threads"] == 8


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

    t = Transcriber("large-v3-turbo-q5_1")
    result = t.transcribe(samples).lower()

    assert "hello" in result and "world" in result, f"got: {result!r}"
```

- [ ] **Step 3: Run fast tests to verify they fail**

Run: `uv run pytest tests/test_transcribe.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mumbler.transcribe'`. The `@pytest.mark.slow` test is deselected by the `addopts` config.

- [ ] **Step 4: Implement `transcribe.py`**

Write `src/mumbler/transcribe.py`:

```python
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
        model: str = "large-v3-turbo-q5_1",
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
```

- [ ] **Step 5: Run fast tests to verify they pass**

Run: `uv run pytest tests/test_transcribe.py -v`
Expected: 4 fast tests PASS; slow test deselected.

- [ ] **Step 6: Run the slow integration test once locally**

Run: `uv run pytest tests/test_transcribe.py -v -m slow`
Expected: 1 test PASS within ~5–10 seconds (includes a ~2 s model load + Metal warmup on first run; pywhispercpp will auto-download the GGUF if it isn't cached).

If this fails because the GGUF isn't downloaded automatically, fall back to fetching it manually:
```bash
mkdir -p models
curl -L -o models/ggml-large-v3-turbo-q5_1.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_1.bin
```
Then re-run the slow test. If it still fails, inspect the actual `result` string from the assertion message — accept any transcription that contains "hello" and "world" in any casing.

- [ ] **Step 7: Commit**

```bash
git add src/mumbler/transcribe.py tests/test_transcribe.py tests/fixtures/hello_world.wav scripts/make_test_fixture.py
git commit -m "feat(transcribe): pywhispercpp wrapper with fixture-backed integration test"
```

---

## Task 5: `hotkey.py` — pynput listener

**Files:**
- Create: `src/mumbler/hotkey.py`
- Create: `tests/test_hotkey.py`

No automated test for the actual `pynput` listener — we test only the small piece of logic we own (mapping a press/release into `on_press`/`on_release` callbacks for the configured key, ignoring other keys).

- [ ] **Step 1: Write the failing test**

Write `tests/test_hotkey.py`:

```python
"""Tests for mumbler.hotkey._Dispatcher (the testable core)."""

from __future__ import annotations

from mumbler.hotkey import Dispatcher


class _FakeKey:
    """Tiny stand-in for pynput.keyboard.Key with a stable identity."""

    def __init__(self, name: str):
        self.name = name

    def __eq__(self, other) -> bool:
        return isinstance(other, _FakeKey) and self.name == other.name

    def __hash__(self) -> int:
        return hash(self.name)


def test_press_then_release_of_target_key_fires_callbacks_in_order():
    target = _FakeKey("alt_r")
    events: list[str] = []
    d = Dispatcher(
        target_key=target,
        on_press=lambda: events.append("press"),
        on_release=lambda: events.append("release"),
    )

    d.handle_press(target)
    d.handle_release(target)

    assert events == ["press", "release"]


def test_unrelated_keys_are_ignored():
    target = _FakeKey("alt_r")
    other = _FakeKey("space")
    events: list[str] = []
    d = Dispatcher(
        target_key=target,
        on_press=lambda: events.append("press"),
        on_release=lambda: events.append("release"),
    )

    d.handle_press(other)
    d.handle_release(other)

    assert events == []


def test_repeated_presses_without_release_only_fire_press_once():
    target = _FakeKey("alt_r")
    events: list[str] = []
    d = Dispatcher(
        target_key=target,
        on_press=lambda: events.append("press"),
        on_release=lambda: events.append("release"),
    )

    d.handle_press(target)
    d.handle_press(target)  # macOS auto-repeats while a key is held
    d.handle_press(target)
    d.handle_release(target)

    assert events == ["press", "release"]


def test_release_without_press_is_ignored():
    target = _FakeKey("alt_r")
    events: list[str] = []
    d = Dispatcher(
        target_key=target,
        on_press=lambda: events.append("press"),
        on_release=lambda: events.append("release"),
    )

    d.handle_release(target)
    assert events == []
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/test_hotkey.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mumbler.hotkey'`

- [ ] **Step 3: Implement `hotkey.py`**

Write `src/mumbler/hotkey.py`:

```python
"""Global push-to-talk hotkey listener.

Splits the logic in two pieces:
- `Dispatcher` — pure state machine, unit-testable, no pynput involvement.
- `listen()` — wires Dispatcher to pynput.keyboard.Listener and blocks.
"""

from __future__ import annotations

from typing import Any, Callable


class Dispatcher:
    """Maps raw key events to push/release callbacks for one target key.

    `target_key` must be `==`-comparable to whatever pynput hands us
    (in practice, a `pynput.keyboard.Key` enum value).
    """

    def __init__(
        self,
        target_key: Any,
        on_press: Callable[[], None],
        on_release: Callable[[], None],
    ) -> None:
        self._target = target_key
        self._on_press = on_press
        self._on_release = on_release
        self._held = False

    def handle_press(self, key: Any) -> None:
        if key != self._target:
            return
        if self._held:
            return  # ignore OS auto-repeat
        self._held = True
        self._on_press()

    def handle_release(self, key: Any) -> None:
        if key != self._target:
            return
        if not self._held:
            return
        self._held = False
        self._on_release()


def listen(
    on_press: Callable[[], None],
    on_release: Callable[[], None],
    target_key: Any | None = None,
) -> None:
    """Block forever, firing `on_press`/`on_release` for the target key.

    Uses `pynput.keyboard.Listener`. Requires macOS Accessibility permission;
    if it's missing, pynput raises immediately and we surface the error.
    """
    from pynput import keyboard  # lazy import for testability

    if target_key is None:
        target_key = keyboard.Key.alt_r

    dispatcher = Dispatcher(target_key, on_press, on_release)

    with keyboard.Listener(
        on_press=dispatcher.handle_press,
        on_release=dispatcher.handle_release,
    ) as listener:
        listener.join()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_hotkey.py -v`
Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/mumbler/hotkey.py tests/test_hotkey.py
git commit -m "feat(hotkey): Dispatcher state machine + pynput listen()"
```

---

## Task 6: `cli.py` — wire everything together

**Files:**
- Create: `src/mumbler/cli.py`
- Create: `tests/test_cli.py`

The CLI exposes `main()`. We test the run-loop wiring with fakes (no real model, no real audio, no real keystrokes).

- [ ] **Step 1: Write the failing test**

Write `tests/test_cli.py`:

```python
"""Tests for mumbler.cli — wiring between the modules."""

from __future__ import annotations

import time
from dataclasses import dataclass, field

import numpy as np

from mumbler import cli


@dataclass
class FakeRecorder:
    started: int = 0
    stopped: int = 0
    samples_to_return: np.ndarray = field(
        default_factory=lambda: np.array([0.1, 0.2], dtype=np.float32)
    )

    def start_recording(self) -> None:
        self.started += 1

    def stop_recording(self) -> np.ndarray:
        self.stopped += 1
        return self.samples_to_return


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

    def __call__(self, text: str) -> None:
        self.calls.append(text)


def test_full_press_release_cycle_records_transcribes_pastes():
    rec = FakeRecorder()
    tr = FakeTranscriber(text="hello world")
    paste = PasteSpy()

    runner = cli.Runner(
        recorder=rec,
        transcriber=tr,
        paste_fn=paste,
        min_hold_ms=0,
        clock=time.monotonic,
    )

    runner.on_press()
    runner.on_release()

    assert rec.started == 1
    assert rec.stopped == 1
    assert len(tr.calls) == 1
    assert paste.calls == ["hello world"]


def test_press_shorter_than_min_hold_discards():
    rec = FakeRecorder()
    tr = FakeTranscriber()
    paste = PasteSpy()
    fake_now = [0.0]
    runner = cli.Runner(
        recorder=rec,
        transcriber=tr,
        paste_fn=paste,
        min_hold_ms=200,
        clock=lambda: fake_now[0],
    )

    fake_now[0] = 0.0
    runner.on_press()
    fake_now[0] = 0.05  # 50ms — below threshold
    runner.on_release()

    assert rec.started == 1
    assert rec.stopped == 1  # stream is still closed cleanly
    assert tr.calls == []  # no transcription
    assert paste.calls == []  # no paste


def test_empty_transcript_does_not_paste():
    rec = FakeRecorder()
    tr = FakeTranscriber(text="   ")
    paste = PasteSpy()
    runner = cli.Runner(
        recorder=rec,
        transcriber=tr,
        paste_fn=paste,
        min_hold_ms=0,
        clock=time.monotonic,
    )

    runner.on_press()
    runner.on_release()

    assert tr.calls != []  # transcription ran
    assert paste.calls == []  # but nothing pasted


def test_press_during_transcription_is_ignored():
    rec = FakeRecorder()
    tr = FakeTranscriber()
    paste = PasteSpy()
    runner = cli.Runner(
        recorder=rec,
        transcriber=tr,
        paste_fn=paste,
        min_hold_ms=0,
        clock=time.monotonic,
    )

    # Simulate: press, release, then a new press arrives mid-transcription.
    # In this synchronous test we model "mid-transcription" by overriding
    # transcribe() to fire the new press while it runs.
    nested = {"count": 0}

    original_transcribe = tr.transcribe

    def transcribe_with_reentry(samples):
        nested["count"] += 1
        if nested["count"] == 1:
            # while we're transcribing the first utterance, another press arrives
            runner.on_press()
        return original_transcribe(samples)

    tr.transcribe = transcribe_with_reentry  # type: ignore[assignment]

    runner.on_press()
    runner.on_release()

    # The reentrant press must not have started a second recording.
    assert rec.started == 1
    assert paste.calls == ["the cat sat on the mat"]


def test_transcribe_exception_is_caught_and_loop_continues():
    rec = FakeRecorder()

    class BoomTranscriber:
        def __init__(self):
            self.calls = 0

        def transcribe(self, samples):
            self.calls += 1
            raise RuntimeError("boom")

    tr = BoomTranscriber()
    paste = PasteSpy()
    runner = cli.Runner(
        recorder=rec,
        transcriber=tr,  # type: ignore[arg-type]
        paste_fn=paste,
        min_hold_ms=0,
        clock=time.monotonic,
    )

    runner.on_press()
    runner.on_release()  # should NOT raise

    assert tr.calls == 1
    assert paste.calls == []
    # And a second cycle still works.
    runner.on_press()
    runner.on_release()
    assert tr.calls == 2
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/test_cli.py -v`
Expected: FAIL — `ImportError` or `AttributeError: module 'mumbler.cli' has no attribute 'Runner'`.

- [ ] **Step 3: Implement `cli.py`**

Write `src/mumbler/cli.py`:

```python
"""CLI entrypoint for mumbler.

`Runner` holds the state machine; `main()` parses args, constructs the real
collaborators, and hands control to `hotkey.listen`.
"""

from __future__ import annotations

import argparse
import sys
import time
import traceback
from typing import Callable, Protocol

import numpy as np


# ----- Protocols (kept narrow so the Runner can accept fakes in tests) -----


class _RecorderLike(Protocol):
    def start_recording(self) -> None: ...
    def stop_recording(self) -> np.ndarray: ...


class _TranscriberLike(Protocol):
    def transcribe(self, samples: np.ndarray) -> str: ...


# ----- Runner -----


class Runner:
    """Per-press state machine. Synchronous; no threads of its own."""

    _IDLE = "idle"
    _RECORDING = "recording"
    _TRANSCRIBING = "transcribing"

    def __init__(
        self,
        recorder: _RecorderLike,
        transcriber: _TranscriberLike,
        paste_fn: Callable[[str], None],
        min_hold_ms: int = 200,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._recorder = recorder
        self._transcriber = transcriber
        self._paste = paste_fn
        self._min_hold_ms = min_hold_ms
        self._clock = clock
        self._state = self._IDLE
        self._press_t = 0.0

    def on_press(self) -> None:
        if self._state != self._IDLE:
            print(
                f"[mumbler] press ignored (state={self._state})",
                file=sys.stderr,
            )
            return
        self._state = self._RECORDING
        self._press_t = self._clock()
        self._recorder.start_recording()

    def on_release(self) -> None:
        if self._state != self._RECORDING:
            return
        samples = self._recorder.stop_recording()
        held_ms = (self._clock() - self._press_t) * 1000
        if held_ms < self._min_hold_ms:
            self._state = self._IDLE
            return

        self._state = self._TRANSCRIBING
        try:
            text = self._transcriber.transcribe(samples)
        except Exception:
            print("[mumbler] transcription failed:", file=sys.stderr)
            traceback.print_exc()
            self._state = self._IDLE
            return

        if text.strip():
            try:
                self._paste(text)
            except Exception:
                print("[mumbler] paste failed:", file=sys.stderr)
                traceback.print_exc()
        self._state = self._IDLE


# ----- main() -----


def _parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="mumbler", description=__doc__)
    p.add_argument("--hotkey", default="alt_r",
                   help="pynput.keyboard.Key name (default: alt_r = Right Option)")
    p.add_argument("--model", default="large-v3-turbo-q5_1",
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
        print("[mumbler] bye", file=sys.stderr)
        return 0
    except Exception as e:
        # pynput raises here when Accessibility permission is missing on macOS;
        # sounddevice raises elsewhere when Microphone permission is missing.
        # Both manifest as opaque OSError/PortAudioError tracebacks otherwise.
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_cli.py -v`
Expected: all 5 tests PASS.

- [ ] **Step 5: Run the full fast suite**

Run: `uv run pytest -v`
Expected: all fast tests across the four test files PASS; slow test deselected.

- [ ] **Step 6: Commit**

```bash
git add src/mumbler/cli.py tests/test_cli.py
git commit -m "feat(cli): wire Runner state machine + main() entrypoint"
```

---

## Task 7: README — install & permissions runbook

**Files:**
- Modify: `README.md` (currently empty)

- [ ] **Step 1: Write `README.md`**

Replace `README.md` (currently 0 bytes) with:

```markdown
# mumbler

Local push-to-talk dictation for macOS Apple Silicon, using a `whisper-large-v3-turbo` model running in-process via `pywhispercpp` with Metal acceleration.

Hold **Right Option** while you speak; release to paste the transcript at the cursor in whatever app has focus.

## Requirements

- macOS on Apple Silicon (tested on M3 Max).
- Python 3.12.
- [`uv`](https://github.com/astral-sh/uv).

## Install

```bash
uv sync --all-groups
```

The first run downloads the Whisper model (~1 GB) into `pywhispercpp`'s cache. To pre-fetch it explicitly:

```bash
curl -L -o models/ggml-large-v3-turbo-q5_1.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_1.bin
```

## macOS permissions

On first launch you'll see two prompts. Approve both:

1. **Microphone** — for the terminal running `mumbler`.
2. **Accessibility** — for the terminal running `mumbler`. Needed so the global hotkey can be captured and ⌘V can be synthesized.

If you denied either by accident, grant it in **System Settings → Privacy & Security**.

## Run

```bash
uv run mumbler
```

You should see:
```
[mumbler] loading model 'large-v3-turbo-q5_1'…
[mumbler] model loaded; hold alt_r to dictate. Ctrl-C to quit.
```

Hold Right Option, speak, release. The transcript appears at the cursor.

## Flags

```
mumbler [--hotkey KEY] [--model NAME_OR_PATH] [--language LANG] [--min-hold-ms MS]
```

- `--hotkey` — any `pynput.keyboard.Key` name. Default `alt_r`.
- `--model` — pywhispercpp model name or absolute path. Default `large-v3-turbo-q5_1`.
- `--language` — Whisper language code, or `auto`. Default `auto`.
- `--min-hold-ms` — presses shorter than this are discarded. Default `200`.

## Tests

```bash
uv run pytest           # fast tests
uv run pytest -m slow   # the integration test that loads the real model
```

## Design

See [`docs/superpowers/specs/2026-05-27-push-to-talk-dictation-design.md`](docs/superpowers/specs/2026-05-27-push-to-talk-dictation-design.md).
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README with install, permissions, and runbook"
```

---

## Task 8: Manual smoke test (the real thing)

This isn't an automated test — it's the runbook for proving end-to-end behavior on the real machine. The plan isn't done until this passes.

- [ ] **Step 1: Make sure permissions are granted**

Open System Settings → Privacy & Security → Microphone. Ensure your terminal (Terminal.app, iTerm2, Ghostty — whichever you launch `mumbler` from) is enabled.

Open System Settings → Privacy & Security → Accessibility. Same terminal, enabled.

- [ ] **Step 2: Launch mumbler**

Run: `uv run mumbler`
Expected output (within ~5 s):
```
[mumbler] loading model 'large-v3-turbo-q5_1'…
[mumbler] model loaded; hold alt_r to dictate. Ctrl-C to quit.
```

If model loading takes more than 30 s, the GGUF is downloading; that's a one-time cost.

- [ ] **Step 3: Open a text target**

Open TextEdit, a new empty document. Click into it so the cursor is active there.

- [ ] **Step 4: Dictate a short sentence**

Hold Right Option, say "the quick brown fox jumps over the lazy dog," release.

Expected: within ~1 s of release, the sentence (or a close approximation) appears in the TextEdit document. The mumbler terminal stays silent (no errors).

- [ ] **Step 5: Dictate a longer passage**

Hold Right Option, speak for ~15 s, release.

Expected: transcript appears within ~1 s.

- [ ] **Step 6: Tap the key briefly (sanity)**

Tap Right Option for < 200 ms. Nothing should happen — no paste, no error.

- [ ] **Step 7: Ctrl-C and exit**

Press Ctrl-C in the mumbler terminal.
Expected:
```
[mumbler] bye
```

- [ ] **Step 8: Commit a runbook note (optional)**

If you found gotchas during the smoke test (e.g. a specific terminal that doesn't surface the Accessibility prompt), capture them as a new short section in README. Then:

```bash
git add README.md
git commit -m "docs(readme): smoke-test findings"
```

---

## Definition of Done

- All Tasks 1–7 committed.
- `uv run pytest -v` passes (fast tests).
- `uv run pytest -v -m slow` passes once on the dev machine (integration test loaded the real model).
- Task 8 smoke test passed end-to-end: held Right Option, spoke, released, text appeared at cursor.
- README documents install, permissions, run, flags, and tests.
- No `modal`-related code left in the repo (other than `uv.lock`, which will be regenerated on the next `uv sync`).
