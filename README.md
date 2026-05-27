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
