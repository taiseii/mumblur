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
    /// Best-effort cleanup. Returns `text` unchanged on any network/timeout/
    /// parse failure, when globally disabled, or when unconfigured. Propagates
    /// `CancellationError` so a cancelled worker never proceeds to paste.
    func editFailOpen(_ text: String, instructions: String) async throws -> String
}
```

Concrete `OpenAICompatibleEditor` is an `actor` holding the **global** server
config (`enabled`, base URL, model, timeout) and an injected `URLSession`:

```swift
public actor OpenAICompatibleEditor: TranscriptEditing {
    public init(config: LLMServerConfig, session: URLSession = .ephemeralForLLM)
    public func configure(_ config: LLMServerConfig) // hot-swap global config
    public func editFailOpen(_ text: String, instructions: String) async throws -> String
}
```

It POSTs to `<baseURL>/v1/chat/completions` with a two-message body (`system` =
per-profile `instructions`, `user` = raw transcript) and returns the assistant
content. The `session` is injected so tests can drive it with a `URLProtocol`
stub instead of `URLSession.shared`.

**Two gates, one contract.** The per-profile gate lives in the snapshot; the
global master switch + reachability live in the editor:

- `Runner` calls `editFailOpen` only when `snapshot.llmEdit.enabled` (per-profile).
- `editFailOpen` short-circuits and returns `text` **without issuing any HTTP
  request** when the editor's global config is disabled (`llm.enabled = 0`) or
  has no usable base URL. This is what makes the global kill-switch real.

**Cancellation vs fail-open.** `editFailOpen` swallows only network/timeout/
non-2xx/parse/empty-completion errors (logs `.info`, returns `text`). It does
**not** swallow `CancellationError` — that propagates so the worker's existing
`catch is CancellationError` path handles it and skips paste.

### Pipeline integration (`Runner.doWork`)

One new stage is inserted **before** the existing rule pass. Note the added
cancellation re-check after the (potentially long) LLM call, mirroring the
existing guard after `transcribe` (Runner.swift:160):

```swift
let output = try await transcriber.transcribe(samples)   // output.rawText
guard !Task.isCancelled else { return }
var text = output.rawText
if output.snapshot.llmEdit.enabled {
    text = try await editor.editFailOpen(text, instructions: output.snapshot.llmEdit.prompt)
    guard !Task.isCancelled else { return }              // do not paste a cancelled run
}
let finalText = postProcessor.apply(text, rules: output.snapshot.rules)
guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
await paster.paste(finalText)
await persister.persist(samples:..., rawText: output.rawText, finalText: finalText)
```

`editor` is injected into `Runner` as a new `any TranscriptEditing` seam
alongside `transcriber`/`paster`/`persister`. `rawText` (stored) remains the
literal Whisper output; `finalText` (stored) is the end of the pipeline
(Whisper + LLM + rules). No separate column for the intermediate LLM output
(YAGNI).

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

New snapshot field — non-optional with a `.disabled` sentinel (clearer than an
optional plus a bool):

```swift
public struct LLMEditConfig: Equatable, Sendable {
    public static let disabled = LLMEditConfig(enabled: false, prompt: "")
    public static let defaultPrompt =
        "Fix punctuation, capitalization, and remove filler words. " +
        "Do not change meaning or add content. Return only the corrected text."
    public let enabled: Bool
    public let prompt: String
}
// ServingSnapshot.init gains: llmEdit: LLMEditConfig = .disabled
```

`ModelManager.requestSwap` resolves the profile fields into `llmEdit`:
`enabled = profile.llmEditEnabled`, and `prompt = profile.llmEditPrompt` unless
that is `nil`/whitespace, in which case it falls back to
`LLMEditConfig.defaultPrompt`. So a `NULL`/empty stored prompt means "use the
default," never "send no instructions."

### Serving refresh on active-profile edits

`ServingSnapshot` only reaches the `Transcriber` via `ModelManager.requestSwap`
(AppCoordinator.swift:213/254). There is **no** auto-refresh today — editing the
active profile's rules/prompt already only takes effect on the next swap. The
per-profile AI fields inherit that same behavior, made explicit:

- Editing a **non-active** profile's AI settings just persists; it applies the
  next time that profile is selected.
- Editing the **active** profile's AI settings must trigger a serving refresh.
  `AppCoordinator` re-issues `requestSwap(to: updatedProfile)` using the existing
  tentative-then-commit pattern (mirroring `setActiveProfileModel`,
  AppCoordinator.swift:239) so the frozen snapshot is rebuilt with the new
  `llmEdit`.

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

Registered by adding `migrator.registerV2()` immediately after the existing
`migrator.registerV1()` call in `Database.runMigrations()` (Database.swift:35).

### Global settings (existing `app_setting` key/value table — no schema change)

| Key | Default | Meaning |
| --- | --- | --- |
| `llm.enabled` | `0` | Master kill-switch; gates the feature regardless of per-profile flags |
| `llm.base_url` | `http://localhost:8080` | OpenAI-compatible server base URL |
| `llm.model` | `""` | Model name (llama.cpp ignores it; Ollama requires it) |
| `llm.timeout_ms` | `5000` | Hard wall-clock budget; clamped to `[500, 60000]`, invalid stored values fall back to default |

These four keys are read/written as a single `LLMServerConfig` value object via
new `SettingsStore` methods (`llmServerConfig()` / `setLLMServerConfig(_:)`),
reusing the `app_setting` upsert idiom from `setActiveProfileID`
(SettingsStore.swift:99).

```swift
public struct LLMServerConfig: Equatable, Sendable {
    public var enabled: Bool          // llm.enabled
    public var baseURL: String        // llm.base_url, normalized (see Scope)
    public var model: String          // llm.model
    public var timeoutMs: Int         // llm.timeout_ms, clamped
}
```

### Domain model changes

- `Profile` gains `llmEditEnabled: Bool` and `llmEditPrompt: String?`. Its public
  init (Profile.swift:16) adds defaulted params
  (`llmEditEnabled: Bool = false, llmEditPrompt: String? = nil`) so existing call
  sites and tests keep compiling.
- `ServingSnapshot` init (ServingSnapshot.swift:15) adds
  `llmEdit: LLMEditConfig = .disabled` (defaulted, same reason).
- **All three** `SettingsStore` touch points carry the new columns:
  `create` (SettingsStore.swift:18, INSERT), `update` (SettingsStore.swift:61,
  UPDATE), and the `Profile(row:db:)` decoder (SettingsStore.swift:145). Existing
  rows read back as `enabled=false, prompt=nil` via the migration defaults.

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

### Wiring (`AppCoordinator`)

`SettingsStore`/`app_setting` are passive — nothing observes them — so the
editor must be reconfigured imperatively. `AIViewModel` writes through
`AppCoordinator` (it does not touch `SettingsStore` directly):

- **Bootstrap:** construct `OpenAICompatibleEditor` from
  `settings.llmServerConfig()` and inject it into `Runner`. Injection slots in
  before `Runner` is built (AppCoordinator.swift:155–167).
- **Global config change:** `AppCoordinator.setLLMServerConfig(_:)` persists via
  `settings.setLLMServerConfig(_:)` **and** `await editor.configure(newConfig)`,
  so URL/model/timeout/enable edits take effect immediately (no profile reload).
- **Per-profile change:** `AppCoordinator.updateProfileAISettings(...)` persists
  via `settings.update(profile)`; if the edited profile is the active one, it
  re-issues `requestSwap` (see "Serving refresh" above).

## Failure & Latency Behavior

- **Hard wall-clock timeout.** `URLSession`'s `timeoutIntervalForRequest` guards
  per-resource stalls, not total elapsed time, so it is not sufficient alone.
  `editFailOpen` races the request against `Task.sleep(timeoutMs)` (a
  `withThrowingTaskGroup` first-result race); whichever finishes first wins and
  the loser is cancelled. The session also sets `timeoutIntervalForRequest =
  timeoutMs` as a backstop.
- **Fail-open triggers:** timeout, connection refused, non-2xx status, malformed
  JSON, empty completion → return the pre-LLM text; log at `.info`.
- **Cancellation is not fail-open.** `CancellationError` (worker shutdown)
  propagates out of `editFailOpen`; with the `guard !Task.isCancelled` after the
  stage, a cancelled run never reaches paste/persist.
- The menu-bar UI stays in the existing `.transcribing` state during the LLM
  call (no new state — YAGNI). The user sees the in-progress indicator.

## Testing

**Runner-level** (`FakeEditor` conforming to `TranscriptEditing` in `RunnerTests`):

- per-profile `enabled` + success → edited text reaches paste
- per-profile `enabled` + thrown network/timeout error → falls back to pre-LLM
  text (fail-open), paste still happens
- per-profile `enabled` + `FakeEditor` throws `CancellationError` → **no** paste/
  persist (cancellation is not fail-open)
- `snapshot.llmEdit.enabled == false` → editor's `editFailOpen` never called
- **ordering**: a replacement rule applied after the LLM overrides an LLM change

**Editor-level** (`OpenAICompatibleEditor` with an injected `URLProtocol` stub
session — no live server):

- global `enabled == false` (or empty base URL) → returns input, **zero** HTTP
  requests issued (this is the global kill-switch contract)
- request body shape (two messages, model field), headers, response decoding
- non-2xx / malformed JSON / empty completion → returns input
- wall-clock timeout race fires when the stub stalls past `timeoutMs`

**Storage:** `registerV2` applies cleanly on a `v1` database and existing rows
read back `llm_edit_enabled = 0`, `llm_edit_prompt = NULL`; `SettingsStore`
round-trips the new profile fields and `LLMServerConfig` (including
clamping/invalid-value handling).

## Scope

- **Calibration bypass — by construction.** Tuning/calibration computes WER from
  `raw_text` vs `final_text`. With the LLM in the pipeline, `final_text` would
  become "Whisper + LLM + rules", conflating model quality with editing quality
  and making WER-driven tuning suggestions meaningless. The editor is injected
  **only into `Runner`, never into `Transcriber`**. `CalibrationController` calls
  `transcriber.transcribe(...)` then `postProcessor.apply(...)` directly
  (CalibrationController.swift:82) — it never goes through `Runner.doWork`, so it
  bypasses LLM editing automatically. The spec forbids placing editing inside
  `Transcriber` precisely to preserve this.
- **Base URL normalization.** The user enters the server **base** (e.g.
  `http://localhost:8080`); the app appends `/v1/chat/completions`. Normalize by
  trimming a trailing `/` and a trailing `/v1` if present, so both
  `http://localhost:8080` and `http://localhost:8080/v1` work.
- **"Test connection"** issues a real minimal chat completion (1-token request),
  not just a TCP/HTTP reachability ping, so it validates the model actually
  responds in the expected shape.
- **Remote URLs allowed.** No loopback-only restriction is enforced; a user may
  point at a non-local OpenAI-compatible server. (Documented, not gated.)
- **Out of scope:** streaming completions, multiple concurrent server profiles,
  storing the intermediate LLM output as a separate transcript column, retries/
  backoff, and any cloud-provider-specific auth. Single OpenAI-compatible
  endpoint only.
- **Known pre-existing limitation (not addressed here):** a profile swap *during*
  a calibration run changes `snapshot.rules` mid-run. This exists today and is
  orthogonal to LLM editing; noted so it isn't mistaken for new behavior.
