# Launch posts

Drafts for every channel worth posting to. Tone: friendly, honest, low-key. No buzzwords, no "revolutionary," no marketing speak. The thing is small and useful; let it be that.

For Show HN see [`HN_POST.md`](HN_POST.md) (longer, separate file because HN is the main shot).

---

## X / Twitter — short

> Made a small thing: Mumblur, a free + open-source macOS dictation app.
>
> Push-to-talk, runs Whisper on-device, optionally cleans up your text via any local LLM you've got running. Edit a past transcript and it learns your style.
>
> No cloud, no account, no subscription.
>
> github.com/taiseii/mumblur

If you have a demo GIF, post it as the first reply, not in the main tweet — the algorithm prefers links in replies.

## X / Twitter — even shorter (for the algo)

> Tired of paying a subscription to send your voice to someone else's server?
>
> Mumblur: free, local, MIT. Push-to-talk dictation that also learns from your corrections via any local LLM.
>
> github.com/taiseii/mumblur

## Bluesky / Mastodon — medium

> Built a small macOS dictation app called Mumblur. Push-to-talk, runs locally with WhisperKit. Optionally hooks into whatever OpenAI-compatible LLM you've got on localhost (llama.cpp, Ollama, etc.) for filler/punctuation cleanup.
>
> The interesting bit: edit any past transcript with what you actually meant, and those edits feed back as few-shot examples for the next dictation. So it gradually learns your style without ever leaving your machine.
>
> MIT licensed. No cloud, no account, no telemetry.
>
> github.com/taiseii/mumblur

---

## Reddit — `/r/MacApps`

**Title:** I made a free local dictation app that learns from your corrections (Mumblur)

**Body:**

Hey folks — sharing a small side project I've been using daily for the last little while. It's a menu-bar app, push-to-talk dictation (Right Option by default), entirely on-device with WhisperKit.

What's a bit different from the usual: every dictation is saved with both the raw Whisper output and the cleaned-up final text. You can go back to any of them later and edit what you actually meant in a "Correction" field. Those edits then get fed as few-shot examples to whatever local LLM you have running — Ollama, llama.cpp, LM Studio, whatever speaks OpenAI's chat-completion API — the next time you dictate. So over time it starts producing text that sounds like you, with zero retraining or cloud involvement.

Other things it does:

- Picks any WhisperKit / Whisper model. Drop in a custom CoreML folder if you've got one.
- Multiple profiles with their own language pin (or auto-detect), vocab prompt, and regex replacement rules.
- Microphone picker in the menu bar (rebinds correctly when USB mics get re-plugged).
- Optional audio retention with day-based or count-based caps. Off by default — text-only mode keeps zero audio.
- Zero telemetry. The only outbound calls are: WhisperKit's first-time model download, and the local LLM cleanup if you've enabled it (and that's localhost).

The build is ad-hoc-signed so you'll need to remove the quarantine attribute on first launch — `xattr -dr com.apple.quarantine /Applications/Mumblur.app`. Notarization is on the roadmap. MIT licensed, all source on GitHub.

Code + downloads: https://github.com/taiseii/mumblur

Happy to answer questions or take feature requests.

---

## Reddit — `/r/LocalLLaMA`

**Title:** macOS dictation app that uses your local LLM for cleanup and learns from your edits

**Body:**

If you've got a llama.cpp / Ollama / LM Studio server running on your Mac, you can now use it to clean up dictation transcripts in real time. I built Mumblur for exactly this — push-to-talk PTT, on-device Whisper for STT (via WhisperKit), then it routes the transcript through whatever OpenAI-compatible endpoint you point it at for filler removal / punctuation / capitalization.

The bit I think this sub will care about: you can correct any past transcript with what you actually meant, and the most recent corrections get injected as `Raw: … / Corrected: …` few-shot blocks into the next dictation's system prompt. So your local model gradually picks up your style without any fine-tuning. The captured `(raw → corrected)` pairs are sitting in plain SQLite — easy to extract later if anyone wants to actually LoRA-train on them.

A few practical notes:

- Works with thinking models if you disable thinking. For Qwen3 you can put `{"chat_template_kwargs": {"enable_thinking": false}}` into the Extra Body JSON field in settings.
- Tiny non-thinking instruct models (Qwen 2.5 Instruct, Llama 3 Instruct, Phi-3) at 3B–7B are honestly the sweet spot for this — for "fix punctuation, remove fillers" you want fast tokens, not chain-of-thought.
- The Test Connection button in settings round-trips a short probe so you can verify connectivity before dictating.

MIT licensed, free, no cloud. github.com/taiseii/mumblur

Would genuinely love feedback on the prompt-augmentation approach vs. just biting the bullet and doing LoRA — interested in how others are handling personalization for ASR cleanup.

---

## Reddit — `/r/macOS` (general audience, shorter)

**Title:** Free, open-source dictation app for Mac that doesn't send your voice anywhere

**Body:**

Quick share — built a small menu-bar dictation app called Mumblur. Hold Right Option, talk, release, your text appears at the cursor. Whisper runs on-device. Free. MIT licensed. No account, no subscription, no telemetry, no cloud.

Optional: if you've got a local LLM running (Ollama, etc.) it can also clean up filler words and punctuation. And you can edit any past transcript with what you actually meant — those corrections feed back into the cleanup over time, so it gradually matches your style.

Binary is ad-hoc-signed so first launch needs `xattr -dr com.apple.quarantine /Applications/Mumblur.app`. Instructions are in the README.

github.com/taiseii/mumblur

---

## Product Hunt — if you want to do it

Honestly, I'd skip Product Hunt for v0.1.0. The audience is more PM/marketer than developer, the upvote algorithm rewards launch-day mobilization more than the project, and an open-source MIT tool with a quarantine workaround doesn't fit the "polished product" mold the site prefers. Better to come back once it's notarized and has a couple of testimonials.

If you do go: lean into the "free, local, no subscription" angle hard. PH users respond to price comparisons more than to technical differentiators.

---

## Things to do before posting anywhere

1. Tag and ship `v0.1.0` so the Releases page has a downloadable binary.
2. Record a ~15-second GIF: menu bar icon → hotkey → dictation → text appears. Embed in README. This single asset matters more than any of the copy above.
3. Decide your "I'm around to answer questions for ~3 hours" window and pick a posting time inside it.
4. Cross-link: when you post on one platform, share that link on the others *as the first reply* on this platform, not as a separate post. Centralized discussion is way better than diluted.
