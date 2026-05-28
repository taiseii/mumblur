# Mumblur — Settings Panel & Local Tuning Store

**Date:** 2026-05-28
**Status:** Design approved, ready for implementation plan
**Depends on:** the shipped push-to-talk MVP (`App/`, `MumblurCore/`)
**Review:** schema validated over two Codex passes; full spec validated over a third
(holistic) Codex pass. The serving-snapshot concurrency model (§9.1), prompt
tokenization (§6.3), and calibration scoring semantics (§10) are products of that pass.

## 1. Summary

Add a native macOS Settings window to Mumblur and a local tuning store so the app
can be personalized per user and per use case. The Settings window exposes language,
model, and per-profile vocabulary + replacement rules. A SQLite database (via GRDB)
captures every dictation (text by default, audio opt-in) for stats, export, and a
**calibration ceremony** that measures transcription accuracy (WER) and proposes
profile-level tuning.

"Tuning" in this release is **configuration, not weight training**: we bias
WhisperKit's prompt, apply deterministic post-transcription rules, and let the user
choose the model. We additionally retain a bounded calibration audio corpus so a
future offline fine-tuner remains possible — but no fine-tuner ships here.

## 2. Goals

- Native Settings window (⌘,) for language, model, profiles, vocab, rules, and data.
- "Tuning profile" = a named bundle of `{language, model, vocab terms, replacement
  rules, optional initial prompt}`; user manually picks the active profile from the
  menu bar dropdown.
- Local SQLite store of every dictation (text-only by default; opt-in audio retention
  with a cap) for stats, export, and future personalization.
- Background model switching with download progress; dictation keeps working on the
  current model until the new one is ready.
- A calibration ceremony that measures WER, mines systematic errors, and proposes
  vocab/rule additions — with an honest before/after report.
- Full data transparency: see where data lives, its size, export it, or wipe it.

## 3. Non-goals (this release)

- No fine-tuning / LoRA / adapter loading. We retain the data that *would* feed an
  offline trainer, but build no trainer.
- No transcript-browser UI (stats + export + reveal + delete-all only).
- No frontmost-app auto-profile switching (manual switch only).
- No semantic search / sqlite-vec / RAG. Schema leaves room to add later.
- No cloud sync, no telemetry, no network beyond WhisperKit model downloads.

## 4. Locked decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Self-correction mechanism | Custom vocab + replacement rules + Whisper initial-prompt bias |
| Profile contents | Full bundle `{name, language, model, vocab, rules, optional prompt}` |
| Profile switching | Manual, from menu bar dropdown |
| General dictation audio | Opt-in, default off, configurable cap (days or count) |
| Calibration audio | **Always** retained (bounded), even when general retention is off |
| Model switching | Background swap with download progress; current model keeps serving |
| Settings shell | Native SwiftUI `Settings` window with sidebar tabs |
| Data transparency | Stats + reveal-in-Finder + export (JSON/CSV) + delete-all; no browser |
| Tuning scope | Config-level (prompt + rules + model). Calibration corpus kept for future trainer. |
| SQLite library | GRDB.swift (single connection, actor-wrapped stores) |
| Vocab → Whisper | Rendered to text, tokenized with the loaded model's tokenizer, and passed as `DecodingOptions.promptTokens`; replacement rules run post-transcription (see §6.3, §9.1) |

## 5. Architecture

```
App/
  AppCoordinator.swift            (extended — owns stores + active Profile; new .swappingModel state)
  Settings/                       NEW
    SettingsScene.swift           Settings scene + sidebar router
    GeneralSettingsView.swift
    ProfilesSettingsView.swift
    ModelsSettingsView.swift
    TuningSettingsView.swift
    DataSettingsView.swift
    AboutSettingsView.swift
MumblurCore/Sources/MumblurCore/
  Profile.swift                   NEW value type (config only; no prompt tokens — see PromptPayload)
  ReplacementRule.swift           NEW value type
  PromptPayload.swift             NEW ({sourceText, promptTokens:[Int], omittedTerms})
  ServingSnapshot.swift           NEW (immutable bundle actually serving dictation; see §9.1)
  PromptBuilder.swift             NEW (renders profile → PromptPayload via a loaded tokenizer, capped)
  TranscriptPostProcessor.swift   NEW (applies rules)
  WERNormalizer.swift             NEW (normalizes text before WER + before mining)
  ModelManager.swift              NEW (list/download/load models; generation-guarded swap; per-model state)
  Storage/                        NEW
    Database.swift                GRDB connection, PRAGMA foreign_keys, migrations
    SettingsStore.swift           Profile CRUD, active-profile pointer, soft-delete, hard-purge
    TranscriptStore.swift         Insert / stats / export
    AudioStore.swift              Optional WAV persistence, sha256, retention sweeper, orphan cleanup
  Tuning/                         NEW
    CalibrationScripts.swift      Fixed scripts (constants) + hashing + mining/eval split
    CalibrationController.swift   Owns recording for the ceremony; suspends the global Runner/hotkey
    WERCalculator.swift           Token-level Levenshtein WER (scoring_version 'wer_v1')
    ErrorMiner.swift              Aligns ground-truth vs raw output; mines produced→expected pairs
    SuggestionGenerator.swift     Proposes vocab terms + replacement rules (support/precision gated)
  Transcriber.swift               (extended — actor holds a ServingSnapshot; transcribe returns raw + snapshot)
  Runner.swift                    (extended — uses the serving snapshot; post-processes; persists)
```

Single GRDB connection owned by `Database`, injected into stores. Stores are `actor`s
so all DB writes serialize off the main thread. `PRAGMA foreign_keys = ON` is set at
every connection open (GRDB does not enable it by default; without it the FK design is
decorative).

Storage location: `~/Library/Application Support/Mumblur/`
- `mumblur.sqlite` (+ `-wal`, `-shm`)
- `clips/<uuid>.wav` — general dictation, only when retention enabled. Filename is a
  UUID generated **before** the DB insert (the transcript row id is not known yet);
  see §6.1 for the write-then-insert protocol.
- `clips/calibration/<run_id>/<sample_index>.wav` — always retained

## 6. Data model (SQLite via GRDB, schema v1)

Reviewed across two Codex (gpt-5.4, high) passes; this is the converged "v3" schema.
All future migrations are linear and additive.

```sql
PRAGMA foreign_keys = ON;        -- enforced at connection open in Database.swift

CREATE TABLE profile (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    language        TEXT,                       -- nil = auto-detect
    model_id        TEXT NOT NULL,              -- WhisperKit model name
    initial_prompt  TEXT,                       -- optional free-form
    created_at      INTEGER NOT NULL CHECK(created_at >= 0),
    updated_at      INTEGER NOT NULL CHECK(updated_at >= created_at),
    deleted_at      INTEGER          CHECK(deleted_at IS NULL OR deleted_at >= created_at)
);
-- Partial unique index: a name may be reused after a soft-delete.
CREATE UNIQUE INDEX idx_profile_name_nocase
    ON profile(name COLLATE NOCASE) WHERE deleted_at IS NULL;

-- Config tables CASCADE: regenerable, nothing irreplaceable, simplifies purge.
CREATE TABLE vocab_term (
    id              INTEGER PRIMARY KEY,
    profile_id      TEXT NOT NULL REFERENCES profile(id) ON DELETE CASCADE,
    term            TEXT NOT NULL,
    UNIQUE(profile_id, term)
);

CREATE TABLE replacement_rule (
    id              INTEGER PRIMARY KEY,
    profile_id      TEXT NOT NULL REFERENCES profile(id) ON DELETE CASCADE,
    pattern         TEXT NOT NULL,
    replacement     TEXT NOT NULL,
    is_regex        INTEGER NOT NULL DEFAULT 0 CHECK(is_regex IN (0,1)),
    case_sensitive  INTEGER NOT NULL DEFAULT 0 CHECK(case_sensitive IN (0,1)),
    word_boundary   INTEGER NOT NULL DEFAULT 1 CHECK(word_boundary IN (0,1)),  -- only when is_regex=0
    sort_order      INTEGER NOT NULL DEFAULT 0 CHECK(sort_order >= 0)
);
CREATE INDEX idx_replacement_rule_profile_sort
    ON replacement_rule(profile_id, sort_order, id);

-- Transcript: RESTRICT protects the corpus from accidental profile delete.
-- Snapshot columns keep history interpretable if the profile later changes.
CREATE TABLE transcript (
    id                      INTEGER PRIMARY KEY,
    profile_id              TEXT REFERENCES profile(id) ON DELETE RESTRICT,
    profile_name_snapshot   TEXT,
    prompt_snapshot         TEXT,
    started_at              INTEGER NOT NULL CHECK(started_at >= 0),
    duration_ms             INTEGER NOT NULL CHECK(duration_ms >= 0),
    model_id                TEXT NOT NULL,
    language                TEXT,
    raw_text                TEXT NOT NULL,      -- pre-rules
    final_text              TEXT NOT NULL,      -- post-rules (what was pasted)
    audio_rel_path          TEXT,
    audio_bytes             INTEGER,
    audio_sha256            TEXT,
    sample_rate_hz          INTEGER,
    channels                INTEGER,
    pcm_encoding            TEXT,
    -- audio metadata is all-or-nothing
    CHECK (
        (audio_rel_path IS NULL AND audio_bytes IS NULL AND audio_sha256 IS NULL
         AND sample_rate_hz IS NULL AND channels IS NULL AND pcm_encoding IS NULL)
        OR
        (audio_rel_path IS NOT NULL AND audio_rel_path <> ''
         AND audio_bytes IS NOT NULL AND audio_bytes >= 0
         AND audio_sha256 IS NOT NULL AND length(audio_sha256) = 64
         AND sample_rate_hz IS NOT NULL AND sample_rate_hz > 0
         AND channels IS NOT NULL AND channels > 0
         AND pcm_encoding IS NOT NULL AND pcm_encoding <> '')
    )
);
CREATE INDEX idx_transcript_started_at ON transcript(started_at DESC);
CREATE INDEX idx_transcript_profile_started_at
    ON transcript(profile_id, started_at DESC) WHERE profile_id IS NOT NULL;

CREATE TABLE calibration_run (
    id                      INTEGER PRIMARY KEY,
    profile_id              TEXT NOT NULL REFERENCES profile(id) ON DELETE RESTRICT,
    profile_name_snapshot   TEXT NOT NULL,
    language_snapshot       TEXT,
    prompt_snapshot         TEXT,
    script_id               TEXT NOT NULL,
    script_hash             TEXT NOT NULL CHECK(script_hash <> ''),     -- SHA-256 of concatenated sentences
    scoring_version         TEXT NOT NULL DEFAULT 'wer_v1',
    started_at              INTEGER NOT NULL CHECK(started_at >= 0),
    completed_at            INTEGER CHECK(completed_at IS NULL OR completed_at >= started_at),
    model_id                TEXT NOT NULL,
    -- Run-level aggregates are computed over the EVALUATION set only (held-out from
    -- mining) to avoid reporting overfit gains. Both raw (pre-rules) and final
    -- (post-rules) are kept so the trend chart can show the rule contribution.
    eval_raw_wer            REAL CHECK(eval_raw_wer IS NULL OR eval_raw_wer >= 0),
    eval_final_wer          REAL CHECK(eval_final_wer IS NULL OR eval_final_wer >= 0),
    notes                   TEXT
);
CREATE INDEX idx_calibration_run_profile_script_started_at
    ON calibration_run(profile_id, script_id, started_at DESC);

CREATE TABLE calibration_sample (
    id              INTEGER PRIMARY KEY,
    run_id          INTEGER NOT NULL REFERENCES calibration_run(id) ON DELETE CASCADE,
    sample_index    INTEGER NOT NULL,
    set_role        TEXT NOT NULL CHECK(set_role IN ('mining','eval')),  -- held-out split
    status          TEXT NOT NULL CHECK(status IN ('recorded','transcribed','failed')),
    ground_truth    TEXT NOT NULL,
    raw_text        TEXT,                       -- Whisper output, pre-rules (for mining)
    final_text      TEXT,                       -- after replacement rules (for trend)
    raw_wer         REAL CHECK(raw_wer IS NULL OR raw_wer >= 0),
    final_wer       REAL CHECK(final_wer IS NULL OR final_wer >= 0),
    error_message   TEXT,
    duration_ms     INTEGER NOT NULL CHECK(duration_ms >= 0),
    audio_rel_path  TEXT NOT NULL CHECK(audio_rel_path <> ''),
    audio_bytes     INTEGER NOT NULL CHECK(audio_bytes >= 0),
    audio_sha256    TEXT NOT NULL CHECK(length(audio_sha256) = 64),
    sample_rate_hz  INTEGER NOT NULL CHECK(sample_rate_hz > 0),
    channels        INTEGER NOT NULL CHECK(channels > 0),
    pcm_encoding    TEXT NOT NULL CHECK(pcm_encoding <> ''),
    UNIQUE(run_id, sample_index),
    -- transcribed rows carry both raw+final result; recorded/failed rows carry none
    CHECK (
        (status = 'transcribed'
            AND raw_text IS NOT NULL AND final_text IS NOT NULL
            AND raw_wer IS NOT NULL AND final_wer IS NOT NULL) OR
        (status IN ('recorded','failed')
            AND raw_text IS NULL AND final_text IS NULL
            AND raw_wer IS NULL AND final_wer IS NULL)
    )
);

-- Compound retention setting modeled explicitly (invariants live together).
-- value is intentionally INDEPENDENT of enabled, so toggling retention off and
-- back on remembers the user's preferred cap.
CREATE TABLE retention_policy (
    singleton   INTEGER PRIMARY KEY CHECK(singleton = 1),
    enabled     INTEGER NOT NULL    CHECK(enabled IN (0,1)),
    kind        TEXT    NOT NULL    CHECK(kind IN ('days','count')),
    value       INTEGER NOT NULL    CHECK(value >= 0)
);
INSERT INTO retention_policy(singleton, enabled, kind, value) VALUES (1, 0, 'days', 30);

-- Misc single-user flags: active_profile_id, schema_version, launch_at_login, etc.
CREATE TABLE app_setting (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

### 6.1 Application-layer rules (not expressible in DDL)

- `Database.swift` runs `PRAGMA foreign_keys = ON` on every connection open.
- All "list profiles" queries filter `WHERE deleted_at IS NULL`.
- Calibration scripts are constants in `Tuning/CalibrationScripts.swift`. `script_id`
  is the script slug; `script_hash` is captured at run time so re-runs against a
  modified script are detectable.
- A calibration sample's WAV is written **before** transcription. The row is inserted
  with `status='recorded'` (and its `set_role`), then UPDATEd atomically to
  `'transcribed'` (with `raw_text`, `final_text`, `raw_wer`, `final_wer`) or
  `'failed'` (with `error_message`).
- **General-dictation audio persistence ordering** (when retention enabled): the WAV
  filename is a UUID generated before insert. Write to a temp file → fsync → move into
  place → compute sha256 → insert the transcript row *with* audio metadata in a single
  transaction. If the file write fails, no row is written; if the app dies between move
  and insert, an **orphan-cleanup sweep on launch** deletes `clips/*.wav` files not
  referenced by any `transcript.audio_rel_path`. This avoids both rows-without-audio and
  orphaned WAVs.
- **Prompt tokens are model-coupled.** WhisperKit takes `DecodingOptions.promptTokens:
  [Int]`, not a string, and tokenization requires a loaded model's `WhisperTokenizer`.
  A profile's prompt is therefore tokenized at model-swap-commit time against the model
  being committed and frozen into the `ServingSnapshot` (§6.3, §9.1) — never recomputed
  per dictation.
- **Hard-purge** of a profile and all its data is one transaction:
  ```sql
  BEGIN;
  DELETE FROM transcript      WHERE profile_id = :id;
  DELETE FROM calibration_run WHERE profile_id = :id;   -- cascades samples
  DELETE FROM profile         WHERE id = :id;            -- cascades vocab_term + replacement_rule
  COMMIT;
  ```
  Soft-delete (the default UI action) only sets `deleted_at` and preserves everything.

### 6.2 Known limitation (accepted)

`COLLATE NOCASE` is ASCII-oriented and does not Unicode-normalize. Two profile names
that differ only by Unicode normalization form could both exist. For a single-user app
where names are typed by hand this is near-impossible, so we accept it rather than
maintain a normalized `name_key` column. Revisit if it ever bites.

## 6.3 WhisperKit API constraints (verified against vendored source)

Confirmed against `argmax-oss-swift` as checked out in `MumblurCore/.build/checkouts/`:

| Capability | Reality | Citation |
|---|---|---|
| Per-call text prompt | **No** `initialPrompt: String`. Decoder takes `DecodingOptions.promptTokens: [Int]?` (prepended to prefill) and `prefixTokens: [Int]?`. | `Configurations.swift:146-147,173-174,202-203` |
| Text → tokens | `WhisperTokenizer.encode(text:) -> [Int]`, reachable via `WhisperKit.tokenizer` — only after a model is loaded. | `Models.swift:1151-1172`, `WhisperKit.swift:22` |
| List models | `static func fetchAvailableModels(...)` | `WhisperKit.swift:219` |
| Download w/ progress | `static func download(..., progressCallback: ProgressCallback?)` | `WhisperKit.swift:244-290` |
| Load / unload | `loadModels(...)`, `unloadModels()`, `clearState()` | `WhisperKit.swift:358,487,501` |

**Implications baked into this design:**
- A profile's vocab + initial prompt are rendered to text by `PromptBuilder`, tokenized
  with the loaded model's tokenizer, truncated to a token budget, and stored as a
  `PromptPayload` inside the active `ServingSnapshot`.
- "Switching models" = constructing a fresh `WhisperKit`/`loadModels`, then committing
  it (not mutating a live instance) — see §9.1.
- These facts should be re-confirmed by a tiny **integration spike** in Phase 2 before
  the rest of the pipeline is built on them (§15).

## 7. Settings window

Native SwiftUI `Settings` scene, opened via ⌘, or "Settings…" in the menu bar. Sidebar tabs:

| Tab | Contents |
|---|---|
| **General** | Active profile picker (mirrors menu bar), min-hold-ms, launch-at-login toggle, hotkey display |
| **Profiles** | Profile list (add / duplicate / rename / soft-delete) → editor: language, model, initial prompt, vocab terms, replacement rules (drag-reorder; regex/case/word-boundary toggles; live "test against sample text" box) |
| **Models** | Installed / available models with status (Installed / Not installed / Downloading N%); download / delete / set-as-default; disk size + RAM hint per model |
| **Tuning** | Calibration ceremony launcher; past-run history with WER trend chart (Swift Charts); per-run drill-down; "apply suggestions" review |
| **Data** | Storage location + Reveal in Finder; DB size; text-vs-audio breakdown; transcript count; oldest/newest entry; retention policy editor; Export (JSON / CSV); Export training corpus; Delete All |
| **About** | Version; honesty note on how tuning works; links |

## 8. Profile lifecycle

- App ships a seeded **"Default"** profile (language auto, model = resolved turbo,
  no vocab/rules) so dictation works before any setup.
- `active_profile_id` lives in `app_setting`; the menu bar shows the active profile
  name and switches in one click.
- Soft-delete sets `deleted_at`: the profile leaves all pickers but its corpus and
  transcripts survive. The last remaining active profile cannot be soft-deleted
  (the app must always have ≥1 selectable profile).
- Hard-purge ("Delete profile **and its data**") is a separate, explicitly-confirmed
  action using the transaction in §6.1.
- Switching the active profile while idle is instant **unless** the new profile's
  model differs from the loaded one → triggers a background model swap (§9).

## 9. Model management

`ModelManager` (actor) wraps `WhisperKit.fetchAvailableModels()` + download, and
publishes per-model state: `notInstalled / downloading(progress) / installed / loaded`.

- One model loaded at a time (the active profile's). On a profile/model switch, the
  currently-loaded model keeps serving dictation until the new model finishes loading,
  then the swap is atomic.
- `AppCoordinator` gains a `.swappingModel(progress:)` UI state, distinct from
  `.loadingModel` (first-launch cold start). The menu-bar icon only shows the swap
  state if a dictation is attempted mid-swap.
- Download progress is surfaced in the Models and Tuning tabs. Picking an uninstalled
  model never blocks dictation on the current model.

### 9.1 Serving snapshot & swap concurrency (Swift 6)

The naive design — "resolve active profile at dictation time" while "the old model keeps
serving until the new one loads" — can transcribe with model A while applying profile B's
language/prompt/rules and persisting mismatched metadata. To prevent this, what actually
serves dictation is a single immutable value:

```swift
struct ServingSnapshot: Sendable {
    let profileID: String
    let profileName: String
    let modelID: String
    let language: String?
    let prompt: PromptPayload          // tokenized against THIS model
    let rules: [ReplacementRule]
}
```

- The `Transcriber` actor holds the current `ServingSnapshot` + its loaded pipeline and
  returns the snapshot alongside the raw text, so the persisted row's
  model/profile/prompt always match what produced it.
- **Selecting** a profile/model sets a *pending* selection; it only becomes the serving
  snapshot once its model is loaded and its prompt tokenized. Until then, dictation keeps
  using the previous snapshot in full (model **and** profile config stay consistent).
- **Actor reentrancy guard:** `ModelManager` carries a monotonic `generation` counter.
  A swap captures its generation before awaiting the (slow) load; after the load it
  commits **only if** its generation is still current, else it discards the result.
  This prevents a slow older swap from clobbering a newer one. Obsolete downloads are
  cancelled where the API allows.

```swift
actor ModelManager {
    private var generation: UInt64 = 0
    func requestSwap(to pending: PendingSelection) async {
        generation += 1; let mine = generation
        let pipeline = try await load(pending.modelID)          // slow; suspension point
        let payload  = PromptBuilder.build(pending.profile, tokenizer: pipeline.tokenizer)
        guard mine == generation else { pipeline.unload(); return }
        await transcriber.commit(ServingSnapshot(...payload...), pipeline: pipeline)
    }
}
```

## 10. Calibration ceremony

Lives in `MumblurCore/Tuning/`. A `CalibrationController` owns recording for the
ceremony and **suspends the global hotkey/Runner** for its duration
(`appCoordinator.suspendDictation(reason: .calibration)` / `resume...` in a `defer`),
so a calibration recording can never be pasted into the frontmost app or stored as a
normal transcript.

**Held-out split (mandatory).** Every script declares a `miningSet` and a disjoint
`evaluationSet`. Suggestions are mined **only** from the mining set; the improvement the
UI reports is the **evaluation-set** WER. This prevents reporting gains that are just
overfit to the sentences we mined from.

**Scoring is dual.** Each transcribed sample stores both `raw_wer` (Whisper output,
pre-rules — what mining needs) and `final_wer` (after replacement rules — what the trend
chart shows). All WER goes through a shared `WERNormalizer` (case, punctuation, number
formatting, whitespace) feeding token-level Levenshtein `WERCalculator`
(`scoring_version='wer_v1'`).

Flow:

1. **Start** — confirm active profile. Snapshot profile name/language/prompt + script
   hash into a new `calibration_run` (no `completed_at`). Suspend dictation.
2. **Record loop** — present sentence *i*; record via `CalibrationController`; persist
   WAV to `clips/calibration/<run_id>/<i>.wav`; insert a `calibration_sample` with its
   `set_role`, `status='recorded'`, and audio integrity fields.
3. **Transcribe & score** — run each sample through the active model; compute `raw_text`
   then `final_text` (rules applied) and their WERs; UPDATE to `'transcribed'` or, on
   failure, `'failed'` (+`error_message`).
4. **Mine (mining set only)** — `ErrorMiner` aligns `ground_truth` vs `raw_text` (post
   `WERNormalizer`) and collects **produced→expected** substitution pairs (note the
   direction: a replacement rule rewrites what Whisper *produced* into the *expected*
   text). `SuggestionGenerator` emits:
   - vocab terms: expected tokens frequently missed, for prompt biasing;
   - replacement rules: produced→expected mappings that clear **support** (min
     occurrences) and **precision** (the produced form maps to that expected form
     consistently, not ambiguously) thresholds — so we don't generate rules that
     corrupt correct output.
5. **Review** — user accepts/rejects each suggestion; accepted ones write to the
   profile's `vocab_term` / `replacement_rule`. Compute `eval_raw_wer` + `eval_final_wer`
   over the evaluation set; set `completed_at`.
6. **Re-measure** — run another `calibration_run` with the updated profile. The Tuning
   tab charts evaluation-set `final_wer` across runs (with raw as a secondary series)
   and shows per-term hit-rate deltas.

**Honesty surface:** the ceremony intro and the About tab state plainly that this tunes
the prompt and post-processing rules, **not** the model weights — and that the reported
improvement is measured on held-out sentences.

## 11. Pipeline integration

`Runner` extends from `recorder → transcriber → paster` to:

```
onRelease → stop recording → samples
  → Transcriber.transcribe(samples)
      → (rawText, servingSnapshot)          // snapshot = profile+model+prompt+rules that served
  → TranscriptPostProcessor.apply(rawText, rules: servingSnapshot.rules) → finalText
  → Paster.paste(finalText)
  → persist using servingSnapshot's profile/model/language/prompt metadata
      (write audio first if retention enabled, then insert row in one txn — §6.1)
```

- The `Transcriber` actor reads its current `ServingSnapshot` (language + tokenized
  prompt already frozen) and returns it with the raw text, so persisted metadata always
  matches what produced the text. The old hardcoded `language: nil` / prompt-less call
  is gone (§9.1).
- **Paste happens before the DB write.** Persistence must never delay the user seeing
  their text; DB write failures log + surface a non-fatal badge. (Persistence is still
  off the hot path, but is no longer naive fire-and-forget: when retention is on it
  follows the write-then-insert-in-one-transaction protocol with launch-time orphan
  cleanup — §6.1.)
- General-dictation audio is persisted only when `retention_policy.enabled=1`.

## 12. Error handling

| Failure | Behavior |
|---|---|
| DB open fails | Fatal — app cannot function. `.fatalError` with a "reveal data folder" escape hatch. |
| DB write fails (post-paste) | Log + transient menu-bar warning. Text already pasted; transcript row lost. Non-fatal. |
| Model download fails | Surfaced in Models/Tuning tab with retry. Dictation continues on current model. |
| Calibration transcribe fails | Sample marked `'failed'`; ceremony continues. Audio retained regardless. |
| Audio file missing / sha256 mismatch | Flagged in Data tab corpus audit (and on export). Not a crash. |
| Regex rule fails to compile | Validated at rule-save time (can't save a broken regex). Defensive skip + log at apply time. |

## 13. Testing

- **`MumblurCoreTests`** (extend existing fast suite): `WERNormalizer` (case/punct/number
  cases), `WERCalculator` (known string pairs incl. insert/delete/substitute),
  `TranscriptPostProcessor` (literal/regex/case/word-boundary, rule ordering),
  `ErrorMiner` (alignment + produced→expected direction), `SuggestionGenerator`
  (support/precision thresholds reject ambiguous/garbage rules), `PromptBuilder`
  (deterministic order, token-budget truncation, omitted-term reporting with a faked
  tokenizer).
- **Concurrency tests:** `ModelManager` generation guard — a slow older swap that
  resumes after a newer one must **not** commit (faked loader with controllable delays);
  serving-snapshot consistency (raw text + snapshot returned together).
- **Storage tests** against a real in-memory GRDB DB (never mocked, per repo
  convention): migration applies cleanly; `PRAGMA foreign_keys=ON` verified; every
  CHECK rejects bad rows (incl. the new dual-WER calibration invariant and `set_role`);
  soft-delete + partial-unique-index name reuse; hard-purge transaction; retention
  sweeper for both `days` and `count` caps; audio orphan-cleanup sweep.
- **Calibration scoring tests:** mining only touches `miningSet`; reported improvement
  is `evaluationSet` WER; both `raw_wer` and `final_wer` recorded.
- **Integration (gated by `MUMBLUR_RUN_SLOW`)**: extend the existing slow test — real
  calibration of a small script against the fixture; assert raw+final WER computed and
  threshold-gated suggestions generated. A separate Phase-2 spike test confirms
  `promptTokens` biasing and model load/swap against real WhisperKit.

## 14. Dependencies

- New SPM dependency: **GRDB.swift** only.
- SHA-256 via CryptoKit; WER trend chart via Swift Charts (both system frameworks).
  WER calculation is hand-rolled.

## 15. Build order (phased around integration boundaries)

A flat linear order risks building `ModelManager` before the `Transcriber`/serving-
snapshot API it must integrate with, and building the whole prompt path on unverified
WhisperKit assumptions. Phased instead:

**Phase 1 — Storage + value types**
1. `Storage/Database.swift` — GRDB dep, connection, `PRAGMA foreign_keys`, v1 migration (full schema) + tests
2. `Profile.swift`, `ReplacementRule.swift`, `PromptPayload.swift`, `ServingSnapshot.swift` value types + tests
3. `Storage/SettingsStore.swift` (profile CRUD, active pointer, soft-delete, hard-purge) + tests
4. `Storage/TranscriptStore.swift` + `AudioStore.swift` (write-then-insert, sha256, retention sweeper, orphan cleanup) + tests

**Phase 2 — WhisperKit reality spike (de-risk before building on it)**
5. `PromptBuilder.swift` + a small integration spike: confirm `promptTokens` biasing,
   tokenizer access, and model load/swap against real WhisperKit (gated slow test).
   Lock the `Transcriber` API shape from what the spike proves.

**Phase 3 — Serving + swap concurrency + pipeline**
6. `Transcriber` change (holds `ServingSnapshot`, returns raw + snapshot) + tests
7. `ModelManager.swift` (generation-guarded swap, download progress) + concurrency tests
8. `Runner` integration (post-process, persist via snapshot) + tests
9. `AppCoordinator` — stores, pending vs serving selection, `.swappingModel` state

**Phase 4 — Tuning**
10. `WERNormalizer`, `WERCalculator`, `ErrorMiner`, `SuggestionGenerator`, `CalibrationScripts` (with mining/eval split) + tests
11. `CalibrationController` (owns recording; suspends Runner) + tests

**Phase 5 — UI**
12. `Settings/` views (General → Profiles → Models → Tuning → Data → About)
13. Menu bar: active-profile switcher + "Settings…" (⌘,)
14. Launch-at-login (`SMAppService`)

## 16. Future work (explicitly deferred)

- Offline fine-tuner (Python trainer + CoreML conversion + custom-model loading). The
  always-retained calibration corpus is the data source for this.
- Transcript browser with inline edits feeding back into suggestions.
- Frontmost-app auto-profile switching.
- Semantic search of past transcripts (sqlite-vec / RAG).
- Unicode-normalized profile-name uniqueness (see §6.2).
