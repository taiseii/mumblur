# Mumbler — Push-to-Talk Local Dictation (MVP)

**Status:** Design approved, pending implementation plan
**Date:** 2026-05-27
**Target machine:** Apple Silicon (M3 Max, macOS), single-user

## 1. Goal

A local CLI tool, `mumbler`, that lets the user dictate text into any macOS application by holding a global push-to-talk hotkey. On release, the recorded audio is transcribed by a local Whisper model and pasted at the cursor in the active app. Everything runs on-device; no network calls.

## 2. Scope

### In scope (v1)

- Foreground CLI process (`mumbler`) started in a terminal.
- Global push-to-talk hotkey, default **Right Option**.
- 16 kHz mono mic capture while hotkey is held.
- Record-then-transcribe: on release, the full buffer is sent to Whisper, then the result is pasted.
- Whisper inference in-process via `pywhispercpp` with Metal acceleration.
- Base model: `ggml-large-v3-turbo-q5_1.bin` (~1.0 GB).
- Multilingual auto-detect.
- Output: paste at cursor in the active app via clipboard + simulated ⌘V.

### Out of scope (v1, deferred to later work)

- MLX LoRA fine-tuning pipeline.
- Streaming transcription / partial results during hold.
- Voice Activity Detection (the hotkey is the gate).
- Menu-bar UI or `.app` bundle.
- launchd daemon / auto-start at login.
- Config file. Settings are CLI flags only in v1.
- Telemetry, error reporting, multi-user support.
- Pasteboard restoration after paste.

## 3. Non-Goals

- Sub-100 ms latency. Target is "feels instant for short utterances," i.e. roughly decode time (~1 s per 30 s of audio on M3 Max with Q5_1).
- Cross-platform support. macOS Apple Silicon only.
- Distribution to other users. The MVP is a personal tool.

## 4. Architecture

### 4.1 Process model

Single long-running Python process. The Whisper model is loaded **once at startup** and kept resident, so per-press latency is just decode time. Hotkey events drive a small state machine on the main thread; audio capture runs in a PortAudio callback thread owned by `sounddevice`; transcription runs synchronously on the main thread on release.

### 4.2 Module layout

```
mumbler/
├── src/mumbler/
│   ├── __init__.py
│   ├── cli.py           # entrypoint, argparse, wires modules together
│   ├── hotkey.py        # pynput global listener; emits press/release callbacks
│   ├── audio.py         # sounddevice mic capture; exposes start/stop returning np.ndarray
│   ├── transcribe.py    # pywhispercpp wrapper; loads model once, transcribes samples
│   └── paste.py         # clipboard write + ⌘V simulation
├── models/              # gitignored; holds ggml-large-v3-turbo-q5_1.bin
├── tests/
│   └── fixtures/        # short WAV fixtures for transcribe tests
├── scripts/
│   └── download_model.sh
└── pyproject.toml
```

### 4.3 Module contracts

Each module exposes a narrow surface so it can be tested in isolation.

**`hotkey.py`**
- `listen(on_press: Callable[[], None], on_release: Callable[[], None], key: pynput.keyboard.Key = Key.alt_r) -> None`
- Blocks the calling thread. Press and release callbacks fire from `pynput`'s listener thread.
- Knows nothing about audio, models, or pasting.

**`audio.py`**
- `start_recording() -> None` — opens a `sounddevice.InputStream` at 16 kHz mono float32, appending frames into an internal list.
- `stop_recording() -> np.ndarray` — closes the stream and returns the concatenated samples as `np.float32` mono.
- Idempotent: a second `stop_recording()` with no intervening start returns an empty array.

**`transcribe.py`**
- `class Transcriber:` constructed once with the model name/path.
  - `__init__(self, model: str = "large-v3-turbo-q5_1", n_threads: int = 8)` — loads the model immediately; this takes ~2 s the first time including Metal warmup.
  - `transcribe(self, samples: np.ndarray) -> str` — runs Whisper, returns the joined transcript stripped of leading/trailing whitespace.
- Owns no I/O beyond what `pywhispercpp` does internally. Does not touch files in v1 (samples go directly to the binding).

**`paste.py`**
- `paste(text: str) -> None` — writes `text` to the macOS pasteboard via `pbcopy`, then synthesizes ⌘V via `pynput.keyboard.Controller`.
- No-op on empty/whitespace strings.
- Does not save/restore previous pasteboard contents in v1.

**`cli.py`**
- Parses args (`--hotkey`, `--model`, `--language`, `--min-hold-ms`).
- Instantiates `Transcriber` (slow; prints a "loading model…" message).
- Defines `on_press` and `on_release` closures that drive the state machine.
- Calls `hotkey.listen(...)` and blocks until Ctrl-C.

### 4.4 Data flow

```
[startup]
   transcriber = Transcriber("large-v3-turbo-q5_1")   # ~2s
   hotkey.listen(on_press, on_release, key=Key.alt_r)

[Right Option pressed]
   t_press = time.monotonic()
   audio.start_recording()

[Right Option released]
   if (time.monotonic() - t_press) * 1000 < min_hold_ms: discard
   samples = audio.stop_recording()
   text    = transcriber.transcribe(samples)
   if text.strip(): paste(text)
```

### 4.5 State machine

States: `IDLE`, `RECORDING`, `TRANSCRIBING`.

- `IDLE` + press → `RECORDING` (start audio).
- `RECORDING` + release → `TRANSCRIBING` (stop audio, run model, paste, → `IDLE`).
- `TRANSCRIBING` + press → ignored (single-flight; warn to stderr).
- Any state + Ctrl-C → clean shutdown (close audio stream, exit).

## 5. External Dependencies

### Python (added to `pyproject.toml`)

- `pywhispercpp` — bundles whisper.cpp with Metal on macOS; in-process inference.
- `sounddevice` — PortAudio binding for mic input.
- `pynput` — global hotkey listener and keystroke synthesis.
- `numpy` — sample buffers (transitive but pinned explicitly).

The existing `modal` dependency stays in `pyproject.toml` for now (it is already pulled in) but is unused in v1. Removal is a follow-up.

### System

- No `brew install whisper-cpp` needed; `pywhispercpp` ships its own build.
- macOS Microphone permission — prompted on first run for the terminal app running `mumbler`.
- macOS Accessibility permission — required by `pynput` for global hotkey capture and ⌘V synthesis. Prompted on first run; if denied, the tool prints a clear error and exits.

### Model

- `models/ggml-large-v3-turbo-q5_1.bin` (~1.0 GB), gitignored.
- `scripts/download_model.sh` curls the file from the `ggerganov/whisper.cpp` Hugging Face repo if absent. `pywhispercpp.Model("large-v3-turbo-q5_1")` will also auto-download on first construction; the script is provided for predictable, scriptable setup.

## 6. CLI Surface (v1)

```
mumbler [--hotkey KEY] [--model PATH_OR_NAME] [--language LANG] [--min-hold-ms MS]

Options:
  --hotkey KEY         Global push-to-talk key. Default: alt_r (Right Option).
                       Accepts any pynput.keyboard.Key name.
  --model PATH_OR_NAME pywhispercpp model name or absolute path to a .bin file.
                       Default: large-v3-turbo-q5_1.
  --language LANG      Whisper language code, or "auto". Default: auto.
  --min-hold-ms MS     Minimum hold duration in ms; shorter presses are discarded.
                       Default: 200.
```

There is no daemon subcommand, no config file, no `init`. v1 is a single foreground command.

## 7. Edge Cases & Error Handling

- **Press < `min_hold_ms`:** discard buffer, do not transcribe, do not paste.
- **Empty / whitespace transcript:** do not paste.
- **`pywhispercpp` raises during transcription:** log to stderr, return to `IDLE`, keep listening.
- **`pbcopy` or ⌘V synthesis fails:** log to stderr, do not exit.
- **Accessibility permission missing:** detected on listener startup; print actionable message ("Grant Accessibility permission to your terminal in System Settings → Privacy & Security → Accessibility") and exit non-zero.
- **Microphone permission missing:** `sounddevice` raises on stream open; same actionable message pattern.
- **Concurrent press during `TRANSCRIBING`:** ignored, single-flight; print a one-line warning so the user notices.
- **Audio device unplugged mid-recording:** `sounddevice` will surface an exception; treat as an empty buffer and return to `IDLE`.

## 8. Testing Strategy

- **`audio.py`** — unit test the buffer-accumulation logic with a fake `InputStream` (monkeypatch `sounddevice.InputStream`); assert that `stop_recording()` returns the concatenation of pushed frames and resets state.
- **`transcribe.py`** — integration test with a fixture WAV (`tests/fixtures/hello_world.wav`, 2–3 s clip). Assert the transcript contains "hello world" (case-insensitive). Slow (~1 s on M3 Max); marked `@pytest.mark.slow` and excluded from a default `pytest` run, included in CI / pre-release.
- **`paste.py`** — write a known string, read it back via `subprocess.run(["pbpaste"], capture_output=True)`. Skip the ⌘V keystroke assertion (no active app in tests); document this gap.
- **`hotkey.py`** — no automated test. Manual smoke test in the runbook.
- **`cli.py`** — wire `Transcriber`, `audio`, `hotkey`, `paste` to fakes; simulate press → release; assert the fake `paste` was called with the fake `Transcriber`'s output.

## 9. Performance Targets

- Cold start (model load + Metal warmup): ≤ 3 s.
- Per-press overhead (excluding decode): ≤ 50 ms.
- Decode latency (large-v3-turbo Q5_1, M3 Max, Metal): roughly 1 s per 30 s of audio for typical dictation. No hard upper bound is asserted; this is a target, not a contract.
- Idle CPU: < 1% (just the hotkey listener and an empty audio handle).

## 10. Open Questions

None blocking the MVP. The following are explicitly deferred to v2:

- Choice of hotkey scheme if Right Option turns out to clash with the user's existing bindings; can be changed via `--hotkey` in the meantime.
- Whether to restore the previous pasteboard contents after paste.
- Whether to surface a small visual indicator (e.g. menu-bar dot) when recording.
- When and how to introduce the MLX fine-tuning pipeline from the original spec.

## 11. Definition of Done

- `uv sync` installs everything; `mumbler` launches and prints "model loaded, listening for <hotkey>".
- Holding Right Option for 3+ seconds while speaking, then releasing, pastes the transcript into a focused TextEdit window within roughly decode time.
- All five modules have the tests described in §8 and `pytest -m "not slow"` passes locally.
- README in the repo root documents the one-time permissions setup and the CLI flags.
- The `modal`-based scaffold (`get_started.py`, the unused `modal` dep) is either removed or clearly marked as unrelated to v1.
