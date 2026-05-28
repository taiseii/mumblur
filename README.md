# Mumblur

Local push-to-talk dictation for macOS. Hold Right Option, speak, release — your words are transcribed by [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) on-device and pasted at the cursor. No network, no cloud, no telemetry.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon recommended (M1+)
- Xcode 16+ to build from source
- ~1 GB free disk for the WhisperKit model on first launch

## Build & install

```bash
brew install xcodegen
xcodegen generate
scripts/build_app.sh --install
open /Applications/Mumblur.app
```

Mumblur lives in the menu bar (no Dock icon). On first launch macOS will request three permissions:

1. **Microphone** — to capture audio
2. **Accessibility** — to synthesize ⌘V at the cursor
3. **Input Monitoring** — to detect the Right Option hotkey globally

The 2 s permission re-check timer picks up grants automatically — no restart needed.

## Usage

Hold **Right Option**, dictate, release. Within ~1 s the transcript appears at the cursor.

Menu bar icon states:
- `mic` — idle, waiting
- `mic.fill` — recording
- `waveform` — transcribing
- `hourglass` — loading model
- `exclamationmark.triangle` — permission needed
- `exclamationmark.octagon` — fatal error

## Layout

- `App/` — SwiftUI menu-bar app target
- `MumblurCore/` — testable Swift package (audio, hotkey, transcribe, paste, runner)
- `scripts/verify_task.sh` — per-task build/test harness
- `scripts/build_app.sh` — release build + ad-hoc sign + optional install
- `docs/superpowers/` — design spec and implementation plan

## Tests

```bash
cd MumblurCore && swift test
```

29 unit tests, ~0.07 s. The slow WhisperKit integration test is gated:

```bash
cd MumblurCore && MUMBLUR_RUN_SLOW=1 swift test --filter TranscriberTests/testIntegration_transcribesHelloWorldFixture
```

Expect ~7 s with the model cached, ~3 min on first run while it downloads.

## Logs

While testing, stream the app's logs in a separate terminal:

```bash
log stream --predicate 'subsystem == "world.questable.mumblur"' --info --debug
```
