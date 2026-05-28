# LLM Transcript Editing — Design

**Date:** 2026-05-28
**Status:** Approved (design); pending implementation plan

## Summary

Add an optional LLM-based editing stage to the dictation pipeline. After Whisper
transcribes audio, the raw text is sent to a locally-running, OpenAI-compatible
LLM server (e.g. llama.cpp's `server`, Ollama, LM Studio, MLX) for cleanup —
punctuation, capitalization, filler-word removal — before the existing
deterministic replacement rules run and the text is pasted.

The feature is **best-effort**: if the LLM is slow, unreachable, or errors, the
pipeline falls back to the un-edited text so dictation never breaks.

## Decisions

| Question | Decision |
| --- | --- |
| Config scope | Per-profile editing behavior (enable + prompt); machine-global server config |
| Failure mode | Fail-open with a configurable timeout |
| Pipeline order | Whisper → **LLM edit** → replacement rules → paste (rules win last) |
| Where editor lives | `MumblurCore`, behind a `TranscriptEditing` protocol seam |
| Calibration | LLM editing is **bypassed** during calibration runs (see Scope) |

## Approaches Considered

- **A — Protocol seam in MumblurCore (chosen).** New `TranscriptEditing`
  protocol + `OpenAICompatibleEditor`, injected into `Runner` exactly like the
  existing `Transcriber`, `Pasting`, and `DictationPersisting` seams. Fully
  testable with a fake.
- **B — Inline HTTP in `Runner.doWork`.** Fewer files, but `Runner` gains
  networking, becomes hard to test, and breaks the seam pattern the core is
  built on. **Rejected.**
- **C — LLM as a special "rule" in `TranscriptPostProcessor`.** Conceptually
  unified but wrong: rules are synchronous/deterministic, the LLM is
  async/networked. Forcing async into the post-processor muddies it and confuses
  ordering. **Rejected.**

## Architecture

### New component: `LLMEditor.swift`

```swift
public protocol TranscriptEditing: Sendable {
    func edit(_ text: String, instructions: String) async throws -> String
}
```

Concrete `OpenAICompatibleEditor` is an `actor` that holds the **global** server
config (base URL, model, timeout) and POSTs to `/v1/chat/completions` with a
two-message body:

- `system`: the per-profile editing `instructions`
- `user`: the raw transcript text

It returns the assistant message content. `AppCoordinator` reconfigures the
editor's global config whenever the AI settings change, so a URL/model/timeout
edit takes effect immediately without a profile reload.

A convenience wrapper provides the fail-open behavior:

```swift
func editFailOpen(_ text: String, instructions: String) async -> String
// returns `text` unchanged on any throw, timeout, non-2xx, malformed JSON,
// or empty completion; logs at .info.
```

### Pipeline integration (`Runner.doWork`)

One new stage is inserted **before** the existing rule pass:

```swift
let output = try await transcriber.transcribe(samples)   // output.rawText
var text = output.rawText
if let cfg = output.snapshot.llmEdit, cfg.enabled {
    text = await editor.editFailOpen(text, instructions: cfg.prompt)
}
let finalText = postProcessor.apply(text, rules: output.snapshot.rules)
guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
await paster.paste(finalText)
await persister.persist(samples:..., rawText: output.rawText, finalText: finalText)
```

`rawText` (stored) remains the literal Whisper output. `finalText` (stored) is
the end of the pipeline (Whisper + LLM + rules). No separate column for the
intermediate LLM output (YAGNI).

### Config split (forced by snapshot freeze-on-swap)

`ServingSnapshot` is built in `ModelManager.requestSwap` from a `Profile` and is
**frozen until the next profile/model swap** (it is not rebuilt per dictation).
This dictates where each piece of config lives:

- **Per-profile** (`enabled`, `prompt`): carried in `ServingSnapshot.llmEdit`,
  sourced from the `Profile`. Refreshes on profile swap, exactly like `rules`
  and `prompt` already do. Correct.
- **Global server** (base URL, model, timeout, master enable): held in
  `OpenAICompatibleEditor`, **not** the snapshot. Baking them into the snapshot
  would make them stale until the next model reload.

New snapshot field:

```swift
public struct LLMEditConfig: Equatable, Sendable {
    public let enabled: Bool
    public let prompt: String
}
// ServingSnapshot gains: public let llmEdit: LLMEditConfig?
```

`ModelManager.requestSwap` resolves `profile.llmEditEnabled` /
`profile.llmEditPrompt` into `llmEdit`.

## Data Model

### Migration: `Storage/MigrationsV2.swift`

```swift
extension DatabaseMigrator {
    mutating func registerV2() {
        registerMigration("v2") { db in
            try db.execute(sql: """
                ALTER TABLE profile ADD COLUMN llm_edit_enabled INTEGER NOT NULL DEFAULT 0
                    CHECK(llm_edit_enabled IN (0,1));
                ALTER TABLE profile ADD COLUMN llm_edit_prompt  TEXT;
            """)
        }
    }
}
```

`registerV2()` is registered alongside `registerV1()` wherever the migrator is
assembled.

### Global settings (existing `app_setting` key/value table — no schema change)

| Key | Default | Meaning |
| --- | --- | --- |
| `llm.enabled` | `0` | Master kill-switch; gates the feature regardless of per-profile flags |
| `llm.base_url` | `http://localhost:8080` | OpenAI-compatible server base URL |
| `llm.model` | `""` | Model name (llama.cpp ignores it; Ollama requires it) |
| `llm.timeout_ms` | `5000` | Request timeout; on expiry → fail-open |

### Domain model changes

- `Profile` gains `llmEditEnabled: Bool` and `llmEditPrompt: String?`.
- `SettingsStore.create` / `update` and the `Profile(row:db:)` decoder updated to
  carry the two new columns.
- Global keys read/written via methods on `SettingsStore` (e.g.
  `llmServerConfig()` / `setLLMServerConfig(...)`), reusing the existing
  `app_setting` upsert idiom (`setActiveProfileID`).

## Settings UI

New **"AI Editing"** tab — `App/Settings/AISettingsView.swift` +
`App/Settings/ViewModels/AIViewModel.swift`, following the existing tab pattern.

- **Global section:** master enable, base URL, model, timeout, and a
  **"Test connection"** button that pings the endpoint and reports reachability.
- **Per-profile section:** enable toggle + a multiline editing-prompt field.
  Default prompt:
  > "Fix punctuation, capitalization, and remove filler words. Do not change
  > meaning or add content. Return only the corrected text."

The per-profile fields could alternatively live in the Profiles tab beside
vocab/rules; the design keeps all LLM config on the AI tab for discoverability.
Final placement can be settled when the view is built.

## Failure & Latency Behavior

- Timeout enforced via the `URLSession` request timeout = `llm.timeout_ms`.
- Fail-open triggers: timeout, connection refused, non-2xx status, malformed
  JSON, empty completion → use the pre-LLM text; log at `.info`.
- The menu-bar UI stays in the existing `.transcribing` state during the LLM
  call (no new state — YAGNI). The user sees the in-progress indicator.

## Testing

Protocol seam enables a `FakeEditor` in `RunnerTests`:

- enabled + success → edited text reaches paste
- enabled + throw / timeout → falls back to pre-LLM text (fail-open)
- disabled (or `llm.enabled = 0`) → editor never called
- **ordering**: a replacement rule applied after the LLM overrides an LLM change
- `OpenAICompatibleEditor` request-building and response-parsing tested via a
  `URLProtocol` stub (request body shape, header, response decoding, error
  paths) — no live server required.

Migration test: `registerV2` applies cleanly on a `v1` database and existing
rows get `llm_edit_enabled = 0`, `llm_edit_prompt = NULL`.

## Scope

- **Calibration bypass.** Tuning/calibration computes WER from `raw_text` vs
  `final_text`. With the LLM in the pipeline, `final_text` would become
  "Whisper + LLM + rules", conflating model quality with editing quality and
  making WER-driven tuning suggestions meaningless. The calibration path
  **bypasses** the LLM editing stage so WER continues to measure Whisper+rules
  only.
- **Out of scope:** streaming completions, multiple concurrent server profiles,
  storing the intermediate LLM output as a separate transcript column, and any
  cloud/remote LLM provider. Single local OpenAI-compatible endpoint only.
