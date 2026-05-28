# Mumblur — Settings Panel & Local Tuning Store

**Date:** 2026-05-28
**Status:** Design approved, ready for implementation plan
**Depends on:** the shipped push-to-talk MVP (`App/`, `MumblurCore/`)

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
| Vocab → Whisper | Rendered into `initialPrompt`; replacement rules run post-transcription |

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
  Profile.swift                   NEW value type (+ renderedPrompt)
  ReplacementRule.swift           NEW value type
  TranscriptPostProcessor.swift   NEW (applies rules)
  ModelManager.swift              NEW (list/download/swap models; publishes per-model state)
  Storage/                        NEW
    Database.swift                GRDB connection, PRAGMA foreign_keys, migrations
    SettingsStore.swift           Profile CRUD, active-profile pointer, soft-delete, hard-purge
    TranscriptStore.swift         Insert / stats / export
    AudioStore.swift              Optional WAV persistence, sha256, retention sweeper
  Tuning/                         NEW
    CalibrationScripts.swift      Fixed scripts (constants) + hashing
    WERCalculator.swift           Token-level Levenshtein WER (scoring_version 'wer_v1')
    ErrorMiner.swift              Aggregates substitution pairs across samples
    SuggestionGenerator.swift     Proposes vocab terms + replacement rules
  Transcriber.swift               (extended — transcribe(samples, language:, initialPrompt:))
  Runner.swift                    (extended — resolves active profile; post-processes; persists)
```

Single GRDB connection owned by `Database`, injected into stores. Stores are `actor`s
so all DB writes serialize off the main thread. `PRAGMA foreign_keys = ON` is set at
every connection open (GRDB does not enable it by default; without it the FK design is
decorative).

Storage location: `~/Library/Application Support/Mumblur/`
- `mumblur.sqlite` (+ `-wal`, `-shm`)
- `clips/<transcript_id>.wav` — general dictation, only when retention enabled
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
    overall_wer             REAL CHECK(overall_wer IS NULL OR overall_wer >= 0),
    notes                   TEXT
);
CREATE INDEX idx_calibration_run_profile_script_started_at
    ON calibration_run(profile_id, script_id, started_at DESC);

CREATE TABLE calibration_sample (
    id              INTEGER PRIMARY KEY,
    run_id          INTEGER NOT NULL REFERENCES calibration_run(id) ON DELETE CASCADE,
    sample_index    INTEGER NOT NULL,
    status          TEXT NOT NULL CHECK(status IN ('recorded','transcribed','failed')),
    ground_truth    TEXT NOT NULL,
    produced_text   TEXT,
    wer             REAL CHECK(wer IS NULL OR wer >= 0),
    error_message   TEXT,
    duration_ms     INTEGER NOT NULL CHECK(duration_ms >= 0),
    audio_rel_path  TEXT NOT NULL CHECK(audio_rel_path <> ''),
    audio_bytes     INTEGER NOT NULL CHECK(audio_bytes >= 0),
    audio_sha256    TEXT NOT NULL CHECK(length(audio_sha256) = 64),
    sample_rate_hz  INTEGER NOT NULL CHECK(sample_rate_hz > 0),
    channels        INTEGER NOT NULL CHECK(channels > 0),
    pcm_encoding    TEXT NOT NULL CHECK(pcm_encoding <> ''),
    UNIQUE(run_id, sample_index),
    -- transcribed rows carry result; recorded/failed rows do not
    CHECK (
        (status = 'transcribed' AND produced_text IS NOT NULL AND wer IS NOT NULL) OR
        (status IN ('recorded','failed') AND produced_text IS NULL AND wer IS NULL)
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
  with `status='recorded'`, then UPDATEd atomically to `'transcribed'`
  (with `produced_text` + `wer`) or `'failed'` (with `error_message`).
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

## 10. Calibration ceremony

Lives in `MumblurCore/Tuning/`. Flow:

1. **Start** — confirm active profile. Snapshot profile name/language/prompt and the
   script hash into a new `calibration_run` (no `completed_at` yet).
2. **Record loop** — present sentence *i*; user holds-to-record via the real
   `AudioRecorder` path; persist WAV to `clips/calibration/<run_id>/<i>.wav`; insert a
   `calibration_sample` with `status='recorded'` and audio integrity fields
   (bytes, sha256, sample rate, channels, encoding).
3. **Transcribe** — run each sample through the active model; UPDATE to `'transcribed'`
   (+`produced_text`,`wer`) or `'failed'` (+`error_message`). WER via `WERCalculator`
   (token-level Levenshtein; `scoring_version='wer_v1'`).
4. **Mine** — `ErrorMiner` aggregates substitution pairs across samples;
   `SuggestionGenerator` proposes vocab terms (frequent expected tokens Whisper missed)
   and replacement rules (stable expected→produced mappings).
5. **Review** — user accepts/rejects each suggestion; accepted ones are written to the
   profile's `vocab_term` / `replacement_rule`. Set `overall_wer` and `completed_at`.
6. **Re-measure (optional)** — re-run the script (or a held-out half) with the updated
   profile → a new `calibration_run`. The Tuning tab charts WER across runs and shows
   per-term hit-rate deltas.

**Honesty surface:** the ceremony intro and the About tab state plainly that this tunes
the prompt and post-processing rules, **not** the model weights.

## 11. Pipeline integration

`Runner` extends from `recorder → transcriber → paster` to:

```
onRelease → stop recording → samples
  → resolve active profile (cached in Runner; refreshed on profile/active change)
  → Transcriber.transcribe(samples, language: profile.language, initialPrompt: profile.renderedPrompt)
      → raw_text
  → TranscriptPostProcessor.apply(raw_text, rules: profile.rules) → final_text
  → Paster.paste(final_text)
  → TranscriptStore.insert(...)   (fire-and-forget actor write; never blocks paste)
```

- `Transcriber.transcribe` signature becomes
  `transcribe(_ samples:, language:, initialPrompt:)`. The previously hardcoded
  `language: nil` and prompt-less call become profile-driven.
- **Paste happens before the DB write.** Persistence must never delay the user seeing
  their text; DB write failures log + surface a non-fatal badge.
- General-dictation audio is persisted only when `retention_policy.enabled=1`; the WAV
  write + sha256 happen on the store actor, off the hot path.

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

- **`MumblurCoreTests`** (extend existing fast suite): `WERCalculator` (known string
  pairs), `TranscriptPostProcessor` (literal/regex/case/word-boundary, rule ordering),
  `ErrorMiner` / `SuggestionGenerator` (synthetic substitution sets),
  `Profile.renderedPrompt`.
- **Storage tests** against a real in-memory GRDB DB (never mocked, per repo
  convention): migration applies cleanly; `PRAGMA foreign_keys=ON` verified; every
  CHECK rejects bad rows; soft-delete + partial-unique-index name reuse; hard-purge
  transaction; retention sweeper for both `days` and `count` caps.
- **`ModelManager`** with a faked downloader/lister: state transitions, swap-while-serving.
- **Integration (gated by `MUMBLUR_RUN_SLOW`)**: extend the existing slow test — real
  calibration of a 2-sentence script against the fixture; assert WER computed and
  suggestions generated.

## 14. Dependencies

- New SPM dependency: **GRDB.swift** only.
- SHA-256 via CryptoKit; WER trend chart via Swift Charts (both system frameworks).
  WER calculation is hand-rolled.

## 15. Build order (maps to plan tasks)

1. `Storage/Database.swift` — GRDB dep, connection, `PRAGMA foreign_keys`, v1 migration (full schema) + tests
2. `Profile.swift`, `ReplacementRule.swift` value types + `renderedPrompt` + tests
3. `Storage/SettingsStore.swift` (profile CRUD, active pointer, soft-delete, hard-purge) + tests
4. `Storage/TranscriptStore.swift` + `AudioStore.swift` (WAV write, sha256, retention sweeper) + tests
5. `TranscriptPostProcessor.swift` + tests
6. `ModelManager.swift` + tests
7. `Tuning/` (`CalibrationScripts`, `WERCalculator`, `ErrorMiner`, `SuggestionGenerator`) + tests
8. `Transcriber` signature change + `Runner` integration + tests
9. `AppCoordinator` — stores, active profile, `.swappingModel` state
10. `Settings/` views (General → Profiles → Models → Tuning → Data → About)
11. Menu bar: active-profile switcher + "Settings…" (⌘,)
12. Launch-at-login (`SMAppService`)

## 16. Future work (explicitly deferred)

- Offline fine-tuner (Python trainer + CoreML conversion + custom-model loading). The
  always-retained calibration corpus is the data source for this.
- Transcript browser with inline edits feeding back into suggestions.
- Frontmost-app auto-profile switching.
- Semantic search of past transcripts (sqlite-vec / RAG).
- Unicode-normalized profile-name uniqueness (see §6.2).
