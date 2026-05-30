# Show HN draft (friendly tone)

## Title — pick one

1. **Show HN: Mumblur – local macOS dictation that learns from your corrections**
2. **Show HN: I made a free macOS dictation app because I was tired of cloud subscriptions**
3. **Show HN: Local Mac dictation with optional local-LLM cleanup**

Option 1 leads with the differentiator and reads neutral. Option 2 is more personal but borders on entitled — fine if you actually feel that way. Option 3 is the safest, most technical phrasing.

## Body

Hey HN — I built Mumblur, a small macOS menu-bar dictation app that runs entirely on your machine.

The honest reason it exists: I dictate a lot, and the options always felt wrong. Built-in macOS dictation hallucinates words and silently sends audio to Apple. Most of the better tools (SuperWhisper, Whisper Memos, etc.) are great but they're paid subscriptions for what feels like a wrapper around Whisper plus an LLM call. So I wrote my own.

Hold Right Option, talk, release. Audio stays on your Mac — [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) does transcription locally. If you want fillers cleaned up, you can point it at a local LLM server (llama.cpp, Ollama, LM Studio — anything that speaks OpenAI's chat-completion API). By default it talks to nothing. No cloud, no account, no telemetry.

The part I had the most fun building, and I'd love feedback on:

Every dictation is saved with both the raw Whisper output and the post-LLM final text. You can open any past transcript and write what you actually meant in a "Correction" field. The last 10 of those `(raw → corrected)` pairs get folded into the next LLM call as few-shot examples. After a few weeks of correcting yourself, the cleanup starts sounding like you. It's just prompt augmentation against your local model — no retraining, no fine-tuning, no uploads. The captured pairs are sitting in plain SQLite though, ready for actual LoRA training if anyone wants to go further.

Other things it does:

- Pick any WhisperKit model, or drop in a custom CoreML folder.
- Multiple profiles, each with its own language pin (or auto-detect), vocabulary prompt, and regex/literal replacement rules. Your hard substitutions always run last and always win.
- Microphone selection from the menu bar — by stable Core Audio UID, so re-plugged USB mics rebind correctly.
- Optional audio retention with day-based or count-based caps. Off by default — text-only mode keeps zero audio on disk.

Stack: Swift 6, SwiftUI, AVAudioEngine, [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift), [GRDB](https://github.com/groue/GRDB.swift) for the SQLite layer. About 150 unit tests and strict TDD across the codebase. MIT licensed.

The binary is ad-hoc-signed (I haven't bought an Apple Developer Program membership yet), so first launch needs `xattr -dr com.apple.quarantine /Applications/Mumblur.app`. README has the full instructions. Notarization is on the roadmap.

Code + downloads: https://github.com/taiseii/mumblur

I'd genuinely love feedback on the few-shot-from-corrections idea — it works surprisingly well at low data volume but obviously caps out. Curious whether anyone has tried something better than prompt-stuffing without going full LoRA.

## Posting checklist

- [ ] Tag `v0.1.0` and run the release workflow so the Releases page has a downloadable `Mumblur.zip` before you post.
- [ ] Record a ~15-second screencap of the menu-bar interaction + one dictation with LLM editing on. Embed the GIF in the README — Show HN engagement is heavily front-loaded and a visual makes a huge difference.
- [ ] Submit at https://news.ycombinator.com/submit during weekday mornings Pacific time (roughly 8–10 a.m. PT).
- [ ] Stay at the keyboard for ~2 hours after posting. HN replies tail off fast if the author goes silent.
- [ ] First reply from your own account: thank early commenters and link to the GIF / a longer demo if you have one.

## Things HN will probably ask

- "Why not just use macOS dictation?" — Built-in routes through Apple servers by default; doesn't expose a hotkey-style PTT; no programmable cleanup layer.
- "Why not SuperWhisper / Whisper Memos / X?" — They're great. They're closed-source, paid, and don't let you swap in your own local LLM for cleanup. Mumblur is OSS, MIT, local-only by default.
- "How is the few-shot actually injected?" — Appended to the system prompt as `Raw: …\nCorrected: …` blocks. Proper alternating user/assistant messages will come when the protocol gains an `examples:` parameter.
- "Linux / Windows?" — WhisperKit is CoreML-only. A different STT backend would be needed; out of scope right now.
- "What about Whisper hallucinations on silence?" — Whisper does this. The replacement-rules and LLM cleanup help a bit. Capturing audio for retention gives you the material to build an eval set if you want to go deeper.
