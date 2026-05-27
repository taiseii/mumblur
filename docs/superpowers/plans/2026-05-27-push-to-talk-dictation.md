# Push-to-Talk Local Dictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `mumbler` MVP from spec `docs/superpowers/specs/2026-05-27-push-to-talk-dictation-design.md` — a local CLI that records audio while a hotkey is held, transcribes it with whisper.cpp via `pywhispercpp`, and pastes the result at the cursor.

**Architecture:** Single Python process. `Transcriber` is constructed once at startup (loads `large-v3-turbo-q5_0` into Metal). `pynput` listens for Right Option globally; on press, `sounddevice` records a 16 kHz mono float32 buffer; on release, the buffer is handed to a **worker thread** that runs `Transcriber.transcribe()` and pastes the result. The worker thread keeps the listener responsive and makes "press during transcription is ignored" a real, testable behavior. Five small modules with narrow contracts so each is independently testable.

**Tech Stack:** Python 3.12, `pywhispercpp`, `sounddevice`, `pynput`, `numpy`, `pytest`. macOS Apple Silicon only.

---

## Verification Harness — read this before executing any task

Because individual tasks may be executed by separate subagents or sessions, every task ends with **the same gate**: a call to `scripts/verify_task.sh N`. The script encodes the per-task contract — which files must exist, which modules must import, which tests must pass — and exits non-zero if any check fails. A subagent picking up Task N can run `scripts/verify_task.sh N-1` first to confirm the world matches what Task N expects.

Conventions:
- **Each task's last step before commit is `scripts/verify_task.sh N`.** If it fails, fix the cause and re-run; do not commit a failing state.
- **Commits land only after `verify_task.sh` passes.** So `git log --oneline` is a reliable execution-progress signal: N commits = first N tasks done.
- **The harness is offline.** No network calls, no model loads in the fast path (it only runs tests that the task itself shipped). The slow integration test in Task 4 is exercised separately.
- **Failure messages tell you what is wrong, not how to fix it.** The plan's task text is the source of truth for how.

The script is created in Task 0 and grows by one branch per task; the additions are included in each later task's diff.

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

- [ ] **Confirm uv is installed**

Run: `uv --version`
Expected: prints a version, exit code 0.

---

## Task 0: Verification harness skeleton

**Why first:** Every other task ends with `scripts/verify_task.sh N`. We need that script (and its Task 0 branch) before any other task can complete.

**Files:**
- Create: `scripts/verify_task.sh`

- [ ] **Step 1: Create the harness script**

Run: `mkdir -p scripts`

Write `scripts/verify_task.sh`:

```bash
#!/usr/bin/env bash
# Verification harness for mumbler. Run `scripts/verify_task.sh N` after Task N.
# Exits 0 with "Task N OK" on success; non-zero with a failure message otherwise.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <task-number>" >&2
    exit 2
fi

TASK="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }
need_file() { [[ -f "$1" ]] || fail "missing file: $1"; }
need_dir()  { [[ -d "$1" ]] || fail "missing dir: $1"; }
absent()    { [[ ! -e "$1" ]] || fail "should not exist: $1"; }
py()        { uv run python -c "$1" >/dev/null; }

case "$TASK" in
    0)
        need_file scripts/verify_task.sh
        [[ -x scripts/verify_task.sh ]] || fail "scripts/verify_task.sh is not executable"
        ;;
    1)
        need_dir src/mumbler
        need_file src/mumbler/__init__.py
        need_dir tests
        need_file tests/__init__.py
        absent main.py
        absent get_started.py
        need_file pyproject.toml
        grep -q '"modal' pyproject.toml && fail "modal dependency should be removed from pyproject.toml"
        grep -q 'pywhispercpp' pyproject.toml || fail "pywhispercpp missing from pyproject.toml"
        py "import mumbler; assert mumbler.__version__"
        ;;
    2)
        bash "$0" 1
        need_file src/mumbler/audio.py
        py "from mumbler.audio import AudioRecorder, SAMPLE_RATE; assert SAMPLE_RATE == 16000"
        uv run pytest tests/test_audio.py -v
        ;;
    3)
        bash "$0" 2
        need_file src/mumbler/paste.py
        py "from mumbler.paste import paste"
        uv run pytest tests/test_paste.py -v
        ;;
    4)
        bash "$0" 3
        need_file src/mumbler/transcribe.py
        need_file tests/fixtures/hello_world.wav
        need_file scripts/make_test_fixture.py
        need_file scripts/download_model.sh
        [[ -x scripts/download_model.sh ]] || fail "scripts/download_model.sh is not executable"
        py "from mumbler.transcribe import Transcriber"
        uv run pytest tests/test_transcribe.py -v -m "not slow"
        ;;
    5)
        bash "$0" 4
        need_file src/mumbler/hotkey.py
        py "from mumbler.hotkey import Dispatcher, listen"
        uv run pytest tests/test_hotkey.py -v
        ;;
    6)
        bash "$0" 5
        need_file src/mumbler/cli.py
        py "from mumbler.cli import Runner, main"
        # Console script registered
        uv run python -c "from importlib.metadata import entry_points; \
            assert any(ep.name == 'mumbler' for ep in entry_points(group='console_scripts'))"
        uv run pytest -v -m "not slow"
        ;;
    7)
        bash "$0" 6
        need_file README.md
        # README must reference the actual model name and the runbook flags
        grep -q 'large-v3-turbo-q5_0' README.md || fail "README must reference large-v3-turbo-q5_0"
        grep -q -- '--hotkey' README.md       || fail "README must document --hotkey"
        grep -q -- '--min-hold-ms' README.md  || fail "README must document --min-hold-ms"
        ;;
    8)
        bash "$0" 7
        # Manual smoke test gate. The runbook in Task 8 is checked off manually;
        # we just confirm that the prior automated gates still hold.
        uv run pytest -v -m "not slow"
        ;;
    *)
        fail "unknown task: $TASK"
        ;;
esac

echo "Task $TASK OK"
```

- [ ] **Step 2: Make the script executable and self-test**

Run:
```bash
chmod +x scripts/verify_task.sh
scripts/verify_task.sh 0
```
Expected: prints `Task 0 OK`, exit 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/verify_task.sh
git commit -m "chore(harness): per-task verification script"
```

---

## Task 1: Project scaffolding & dependencies

**Files:**
- Create: `src/mumbler/__init__.py`
- Create: `tests/__init__.py`
- Modify: `pyproject.toml`
- Modify: `.gitignore`
- Delete (untracked): `main.py`, `get_started.py`

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

Note: `modal` is dropped. `soundfile` is dev-only — needed by the integration test to read the fixture WAV; runtime never touches WAV files.

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
Expected: completes successfully. The first install pulls `pywhispercpp` (which bundles whisper.cpp) and may take a few minutes the first time.

- [ ] **Step 6: Smoke-test the install**

Run: `uv run python -c "import mumbler; import pywhispercpp; import sounddevice; import pynput; import numpy; print('ok')"`
Expected: `ok`, no ImportError.

- [ ] **Step 7: Run harness**

Run: `scripts/verify_task.sh 1`
Expected: `Task 1 OK`.

- [ ] **Step 8: Commit**

```bash
git add pyproject.toml .gitignore src/ tests/
git commit -m "chore: scaffold src/mumbler package and dev dependencies"
```

`main.py` and `get_started.py` are untracked — `rm -f` from Step 3 is sufficient; no `git rm` needed.

---

## Task 2: `audio.py` — mic capture with a fake-injectable stream

**Files:**
- Create: `src/mumbler/audio.py`
- Create: `tests/test_audio.py`

The module exposes an `AudioRecorder` class. The real `sounddevice.InputStream` is the default backend; tests inject a fake factory. Stream errors at stop time (e.g. unplugged device) are caught and converted into an empty buffer.

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
    # And we can start a fresh cycle afterwards.
    rec.start_recording()
    rec.stop_recording()
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_audio.py -v`
Expected: all 6 tests PASS.

- [ ] **Step 5: Run harness**

Run: `scripts/verify_task.sh 2`
Expected: `Task 2 OK` (this also re-verifies Task 1).

- [ ] **Step 6: Commit**

```bash
git add src/mumbler/audio.py tests/test_audio.py
git commit -m "feat(audio): AudioRecorder with injectable stream factory"
```

---

## Task 3: `paste.py` — clipboard write + ⌘V

**Files:**
- Create: `src/mumbler/paste.py`
- Create: `tests/test_paste.py`

The module exposes a `paste(text, send_cmd_v=...)` function. The clipboard side is real (`pbcopy`/`pbpaste`). The keystroke side is injected so tests can assert without an active app.

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
    subprocess.run(["pbcopy"], input="sentinel", text=True, check=True)
    paste("", send_cmd_v=keystroke)
    assert read_pasteboard() == "sentinel"
    assert keystroke.calls == []


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
    from pynput.keyboard import Controller, Key  # lazy import

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

Note: this test mutates the system pasteboard. The `FakeKeystroke` prevents real ⌘V from firing.

- [ ] **Step 5: Run harness**

Run: `scripts/verify_task.sh 3`
Expected: `Task 3 OK`.

- [ ] **Step 6: Commit**

```bash
git add src/mumbler/paste.py tests/test_paste.py
git commit -m "feat(paste): clipboard write + injectable cmd+v synthesis"
```

---

## Task 4: `transcribe.py` — pywhispercpp wrapper + model setup

**Files:**
- Create: `src/mumbler/transcribe.py`
- Create: `tests/test_transcribe.py`
- Create: `tests/fixtures/hello_world.wav` (script-generated)
- Create: `scripts/make_test_fixture.py`
- Create: `scripts/download_model.sh`

Fast tests use a fake model factory. A `@pytest.mark.slow` integration test loads the real model and transcribes a fixture.

- [ ] **Step 1: Generate the test fixture**

We don't want to commit a recording of the developer, and we don't want the test depending on an external TTS install. Synthesize a short clip with macOS `say`.

Write `scripts/make_test_fixture.py`:

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

- [ ] **Step 2: Create the model download script**

Write `scripts/download_model.sh`:

```bash
#!/usr/bin/env bash
# Downloads the Whisper GGUF used by mumbler into ./models/.
# Idempotent: skips download if the file already exists.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODEL_NAME="${1:-ggml-large-v3-turbo-q5_0.bin}"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_NAME}"
MODEL_DIR="$ROOT/models"
DEST="$MODEL_DIR/$MODEL_NAME"

mkdir -p "$MODEL_DIR"
if [[ -f "$DEST" ]]; then
    echo "model already present: $DEST"
    exit 0
fi

echo "downloading $MODEL_NAME …"
curl -L --fail --progress-bar -o "$DEST.partial" "$MODEL_URL"
mv "$DEST.partial" "$DEST"
echo "wrote $DEST ($(du -h "$DEST" | cut -f1))"
```

Make it executable:
```bash
chmod +x scripts/download_model.sh
```

(The slow integration test in Step 6 will run this if the model isn't yet present.)

- [ ] **Step 3: Write the failing tests**

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
```

- [ ] **Step 4: Run fast tests to verify they fail**

Run: `uv run pytest tests/test_transcribe.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mumbler.transcribe'`. The `@pytest.mark.slow` test is deselected by `addopts`.

- [ ] **Step 5: Implement `transcribe.py`**

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
```

- [ ] **Step 6: Run fast tests to verify they pass**

Run: `uv run pytest tests/test_transcribe.py -v`
Expected: 4 fast tests PASS; slow test deselected.

- [ ] **Step 7: Run the slow integration test once locally**

If you haven't already, pre-fetch the model:
```bash
scripts/download_model.sh
```
This writes `models/ggml-large-v3-turbo-q5_0.bin` (~1.0 GB).

Then run: `uv run pytest tests/test_transcribe.py -v -m slow`
Expected: 1 test PASS within ~5–10 s. `pywhispercpp.Model("large-v3-turbo-q5_0")` resolves the model name against its own cache; if it can't find it there it will auto-download. The repo-local `models/` directory is for explicit `--model models/...` usage from the CLI.

If the slow test fails because the transcription doesn't say "hello world" exactly, inspect the printed `result!r` from the assertion message — accept any transcription that contains both words in any casing. If it fails for a different reason (model not found, no Metal device, etc.), do not proceed; fix the root cause.

- [ ] **Step 8: Run harness**

Run: `scripts/verify_task.sh 4`
Expected: `Task 4 OK`.

- [ ] **Step 9: Commit**

```bash
git add src/mumbler/transcribe.py tests/test_transcribe.py tests/fixtures/hello_world.wav \
        scripts/make_test_fixture.py scripts/download_model.sh
git commit -m "feat(transcribe): pywhispercpp wrapper + fixture + model downloader"
```

---

## Task 5: `hotkey.py` — pynput listener

**Files:**
- Create: `src/mumbler/hotkey.py`
- Create: `tests/test_hotkey.py`

We test only the small piece of logic we own: the `Dispatcher` that maps press/release events for the configured key into callbacks, ignoring other keys and OS auto-repeat. The `listen()` wrapper around `pynput.keyboard.Listener` is exercised in the manual smoke test (Task 8).

- [ ] **Step 1: Write the failing test**

Write `tests/test_hotkey.py`:

```python
"""Tests for mumbler.hotkey.Dispatcher."""

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
    d.handle_press(target)
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

Split in two:
- `Dispatcher` — pure state machine, no pynput involvement, unit-testable.
- `listen()` — wires Dispatcher to pynput.keyboard.Listener and blocks.

Callbacks fire on pynput's listener thread. Callers should make on_press /
on_release cheap; long work (Whisper, paste) should happen on a worker.
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
    if missing, pynput raises and we let the exception propagate so cli.main()
    can surface a friendly message.
    """
    from pynput import keyboard

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

- [ ] **Step 5: Run harness**

Run: `scripts/verify_task.sh 5`
Expected: `Task 5 OK`.

- [ ] **Step 6: Commit**

```bash
git add src/mumbler/hotkey.py tests/test_hotkey.py
git commit -m "feat(hotkey): Dispatcher state machine + pynput listen()"
```

---

## Task 6: `cli.py` — wire everything together (worker thread + locked state machine)

**Files:**
- Create: `src/mumbler/cli.py`
- Create: `tests/test_cli.py`

`Runner` holds a locked state machine: `IDLE → RECORDING → TRANSCRIBING → IDLE`. `on_release` spawns a worker thread to do transcribe + paste so the pynput listener thread is free; the lock makes "press during transcription" land on a `state != IDLE` rejection. A `start_worker` callable is injected so tests run the worker synchronously without real threads.

- [ ] **Step 1: Write the failing test**

Write `tests/test_cli.py`:

```python
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/test_cli.py -v`
Expected: FAIL — `ImportError` or `AttributeError: module 'mumbler.cli' has no attribute 'Runner'`.

- [ ] **Step 3: Implement `cli.py`**

Write `src/mumbler/cli.py`:

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_cli.py -v`
Expected: all 7 tests PASS.

- [ ] **Step 5: Run the full fast suite**

Run: `uv run pytest -v`
Expected: every fast test across the five test files passes; slow test deselected.

- [ ] **Step 6: Run harness**

Run: `scripts/verify_task.sh 6`
Expected: `Task 6 OK`.

- [ ] **Step 7: Commit**

```bash
git add src/mumbler/cli.py tests/test_cli.py
git commit -m "feat(cli): worker-thread Runner + main() entrypoint"
```

---

## Task 7: README — install & permissions runbook

**Files:**
- Modify: `README.md` (currently empty)

- [ ] **Step 1: Write `README.md`**

Replace `README.md` with:

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

Pre-fetch the Whisper model (~1 GB) into the repo:

```bash
scripts/download_model.sh
```

This writes `models/ggml-large-v3-turbo-q5_0.bin`. If you skip this step, `pywhispercpp` will auto-download into its own cache on first launch.

To use the file you just downloaded explicitly, pass it as `--model`:
```bash
uv run mumbler --model "$PWD/models/ggml-large-v3-turbo-q5_0.bin"
```

## macOS permissions

On first launch you'll see two prompts. Approve both:

1. **Microphone** — for the terminal running `mumbler`.
2. **Accessibility** — for the terminal running `mumbler`. Needed so the global hotkey can be captured and ⌘V can be synthesized.

If you denied either, grant it in **System Settings → Privacy & Security**.

## Run

```bash
uv run mumbler
```

Expected:
```
[mumbler] loading model 'large-v3-turbo-q5_0'…
[mumbler] model loaded; hold alt_r to dictate. Ctrl-C to quit.
```

Hold Right Option, speak, release. The transcript appears at the cursor.

## Flags

```
mumbler [--hotkey KEY] [--model NAME_OR_PATH] [--language LANG] [--min-hold-ms MS]
```

- `--hotkey` — any `pynput.keyboard.Key` name. Default `alt_r`.
- `--model` — pywhispercpp model name or absolute path. Default `large-v3-turbo-q5_0`.
- `--language` — Whisper language code, or `auto`. Default `auto`.
- `--min-hold-ms` — presses shorter than this are discarded. Default `200`.

## Tests

```bash
uv run pytest                # fast tests
uv run pytest -m slow        # integration test that loads the real model
scripts/verify_task.sh 6     # per-task verification harness (1..8)
```

## Design

See [`docs/superpowers/specs/2026-05-27-push-to-talk-dictation-design.md`](docs/superpowers/specs/2026-05-27-push-to-talk-dictation-design.md).
```

- [ ] **Step 2: Run harness**

Run: `scripts/verify_task.sh 7`
Expected: `Task 7 OK`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README with install, permissions, and runbook"
```

---

## Task 8: Manual smoke test (the real thing)

Not automated — this is the end-to-end runbook on the real machine. The plan isn't done until this passes.

- [ ] **Step 1: Grant macOS permissions**

System Settings → Privacy & Security → **Microphone**: ensure your terminal (Terminal.app, iTerm2, Ghostty — whichever you launch `mumbler` from) is enabled.

System Settings → Privacy & Security → **Accessibility**: same terminal, enabled.

- [ ] **Step 2: Launch mumbler**

Run: `uv run mumbler`
Expected (within ~5 s):
```
[mumbler] loading model 'large-v3-turbo-q5_0'…
[mumbler] model loaded; hold alt_r to dictate. Ctrl-C to quit.
```

If model loading takes > 30 s, the GGUF is downloading; one-time cost.

- [ ] **Step 3: Open a text target**

Open TextEdit, new empty document. Click into it so the cursor is active there.

- [ ] **Step 4: Dictate a short sentence**

Hold Right Option, say "the quick brown fox jumps over the lazy dog," release.

Expected: within ~1 s of release, the sentence (or close approximation) appears in TextEdit. The mumbler terminal stays silent.

- [ ] **Step 5: Dictate a longer passage**

Hold Right Option, speak for ~15 s, release.

Expected: transcript appears within ~1 s of release.

- [ ] **Step 6: Tap the key briefly (min-hold guard)**

Tap Right Option for < 200 ms. Nothing should happen — no paste, no error.

- [ ] **Step 7: Press again during transcription (single-flight)**

Hold Right Option for ~10 s and release; immediately (while transcription is still running) press Right Option again briefly.

Expected: the mumbler terminal prints `[mumbler] press ignored (state=transcribing)`. The first utterance still pastes. The second tap is dropped.

- [ ] **Step 8: Ctrl-C while recording (clean shutdown)**

Hold Right Option and, while still holding, switch to the mumbler terminal and press Ctrl-C.

Expected:
```
[mumbler] bye
```
No traceback. Process exits 0. (The audio stream should be aborted via `runner.shutdown()`.)

- [ ] **Step 9: Run harness one final time**

Run: `scripts/verify_task.sh 8`
Expected: `Task 8 OK`.

- [ ] **Step 10: Commit any runbook findings (optional)**

If the smoke test surfaced gotchas (e.g., a specific terminal that swallowed the Accessibility prompt), capture them as a short section in README:

```bash
git add README.md
git commit -m "docs(readme): smoke-test findings"
```

---

## Definition of Done

- All Tasks 0–7 committed; commit log reads roughly: `chore(harness)`, `chore: scaffold`, `feat(audio)`, `feat(paste)`, `feat(transcribe)`, `feat(hotkey)`, `feat(cli)`, `docs: README`.
- `scripts/verify_task.sh 7` passes from a fresh clone after `uv sync --all-groups`.
- `uv run pytest -v` passes (fast tests across five test files).
- `uv run pytest -v -m slow` passes once on the dev machine (real-model integration test).
- Task 8 manual smoke test passes end-to-end: dictation works, min-hold guard works, single-flight rejection works, Ctrl-C cleanup works.
- README documents install, permissions, run, flags, tests, and links to the spec.
- No `modal`-related code in the repo (other than transient entries in `uv.lock` which `uv sync` rewrites).
