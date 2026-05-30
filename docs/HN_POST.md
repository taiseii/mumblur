# Show HN draft

Two strong title options — pick whichever resonates more after rereading:

1. **Show HN: Mumblur – Local push-to-talk dictation for macOS with optional LLM cleanup**
2. **Show HN: Local macOS dictation that learns your style from your own corrections**

Option 1 is the safest framing. Option 2 leans on the personalization angle (which is the genuine differentiator).

---

## Body

Hi HN — I built Mumblur, a macOS menu-bar dictation tool that runs entirely on-device by default and learns from corrections you make.

The motivation: I dictate a lot, but built-in macOS dictation hallucinates names and refuses to remove fillers, while every "AI dictation" product either uploads my audio to a cloud or wants a subscription for something that ought to be a 200-line state machine. WhisperKit runs Whisper on Apple Silicon at decent speed already; the rest is just glue.

Hold Right Option, speak, release. Audio goes to WhisperKit on-device. If you've configured a local LLM server (llama.cpp / Ollama / LM Studio / anything OpenAI-compatible), the raw transcript is cleaned up — punctuation, fillers, casing — by whatever model you point it at. If you haven't, the raw Whisper text is pasted as-is. No cloud round-trip in either case.

The part I'm most curious about feedback on: every dictation is persisted with both the raw Whisper output and the post-LLM final text. You can open any past transcript and fill in a "Correction" field — what you actually meant to say. The 10 most recent `(raw → corrected)` pairs are then injected as few-shot examples into the next LLM-edit prompt. No retraining, no fine-tuning, no upload — it's just prompt augmentation against a local model. Over a few dozen corrections, the editor starts producing text that looks like yours. The same captured pairs are ready for actual LoRA training later if anyone wants to go further.

Other things it does:
- Pick any WhisperKit model, including custom CoreML folders or arbitrary Hugging Face Whisper variants.
- Per-profile language pinning (English, German, Japanese, …) or auto-detect.
- Regex/literal replacement rules per profile (your hard substitutions always win, after the LLM stage).
- Microphone selection from the menu bar, by stable Core Audio UID so re-plugged USB mics rebind correctly.
- Optional audio retention with day-based or count-based caps. Off by default.

Privacy posture: zero outbound calls unless you've enabled LLM editing, in which case it talks to `localhost` only. Storage is a plain SQLite file under `~/Library/Application Support/Mumblur/` — open it with any browser.

Stack: Swift 6, SwiftUI, AVAudioEngine for capture, Core Audio for input routing, [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) for transcription, [GRDB](https://github.com/groue/GRDB.swift) for persistence. ~150 unit tests; strict TDD across the codebase. MIT licensed.

The build is ad-hoc-signed (no Apple Developer Program), so first launch needs `xattr -dr com.apple.quarantine /Applications/Mumblur.app` — instructions in the README. Notarization is on the roadmap.

Code: https://github.com/taiseii/mumblur
Release: (link to v0.1.0 release after tagging)

Curious whether anyone has a better recipe for the few-shot-vs-LoRA tradeoff for ASR cleanup — prompt-stuffing works well at low data volume but obviously caps out.

---

## Posting checklist

- [ ] Tag `v0.1.0` and run the release workflow (or `scripts/package_release.sh`) so the Releases page has a downloadable `Mumblur.zip` before you post.
- [ ] Pick the title (lean toward option 2 if you want engagement; option 1 if you want clarity).
- [ ] Post to https://news.ycombinator.com/submit during US business hours for visibility (roughly 8am–11am Pacific weekdays).
- [ ] First comment from your own account: link to a 30-second demo GIF/screenshot if you have one. (You don't yet — worth recording the menu-bar interaction and one dictation with LLM edit on, before posting.)
- [ ] Be ready to answer in real time for ~2 hours after posting — HN replies tail off fast if the author goes silent.

## Things HN will probably ask

- "Why not just use macOS dictation?" — built-in is cloud-routed by default; doesn't expose a hotkey-style PTT; no programmable cleanup layer.
- "Why not [SuperWhisper / Whisper-something]?" — those are great but typically closed-source, paid, or don't expose the LLM cleanup stage as a swappable local server. Mumblur is OSS, MIT, local-only by default.
- "How is the few-shot actually injected?" — it's appended to the system prompt as alternating `Raw: …\nCorrected: …` blocks (v1). Proper alternating user/assistant messages will come when the protocol gains an `examples:` parameter.
- "What about Linux/Windows?" — WhisperKit is CoreML-only. A different STT backend would be needed; out of scope right now.
- "What about Whisper hallucinations on silence?" — Whisper does this; we can't fix it from upstream. The post-processor and the LLM cleanup help; capturing audio for retention lets you build an eval set if you want to go deeper.
