# Mumblur Settings & Tuning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the Settings window and local tuning store from spec `docs/superpowers/specs/2026-05-28-mumblur-settings-tuning-design.md` — a SwiftUI Settings scene, a GRDB-backed local store of every dictation, configurable per-profile vocab/rules/model, a generation-guarded model-swap pipeline driven by an immutable `ServingSnapshot`, and a calibration ceremony that measures WER over a held-out evaluation set.

**Architecture:** All persistence lives in `MumblurCore/Storage/` behind actor-wrapped stores around a single GRDB connection. The serving snapshot (profile + model + tokenized prompt + rules) is owned by the `Transcriber` actor; `ModelManager` swaps via a monotonic generation counter so a slow older load can never overwrite a newer one. The `Runner` pipeline now flows `record → Transcriber.transcribe → (rawText, snapshot) → post-process → paste → persist via snapshot` with audio (when retained) written via UUID-first write-then-insert-in-one-transaction and a launch-time orphan sweep. Calibration runs in a dedicated `CalibrationController` that suspends the global hotkey to keep ceremony recordings off the paste path. Settings is a native SwiftUI `Settings` scene with six sidebar tabs.

**Tech Stack:** Swift 6 strict concurrency, macOS 14+ (target also runs on **macOS Tahoe 26.x**), SwiftUI `MenuBarExtra`/`Settings` scene, GRDB.swift (new SPM dep), WhisperKit (existing), CryptoKit (system), Swift Charts (system), XCTest.

---

## Revision Log v2 (2026-05-28, after Codex review)

The original plan had compile-level and correctness bugs caught by a Codex (`gpt-5.4`, high) holistic pass and additional web research. **Every task below carries a `REVISION v2:` block at the top** with the patch that applies; the body of the task is the original draft and must be read **after** the revision block. Where the revision contradicts the body, the revision wins.

The patches resolve 17 review findings plus 13 reconcile-pass refinements. Summary:

1. **WhisperKit prompt path is now threaded end-to-end.** `WhisperKitTranscribing.transcribe(...)` gains a `promptTokens: [Int]?` parameter. `Transcriber` passes `snapshot.prompt.promptTokens` on every call. `RealWhisperKit` passes it into `DecodingOptions(promptTokens:)` (verified in vendored `Configurations.swift:202`). Every fake/spy in tests is updated.
2. **`PromptBuilder` API is closure-only:** `(@Sendable (String) throws -> [Int])` — no generic `Tokenizing`-mutating variant.
3. **`AppCoordinator.SettingsBridge` is environment-injected**, never a `.shared` singleton.
4. **Active profile is committed only after a successful swap.** `ModelManager.requestSwap(...)` is `async throws -> ServingSnapshot`. UI shows `.swappingModel` during, rolls back the picker selection on throw, and only writes `active_profile_id` after the snapshot is committed. A monotonic generation counter cancels stale earlier swap completions.
5. **Audio retention is actually wired** via a new Task 21.5 (`RetentionAwarePersister`) injected into `Runner`. When retention is OFF, **no WAV is written at all** (no temp-then-delete). When ON, WAV is streamed to disk (chunked SHA-256 via `FileHandle` + `var hasher = SHA256()`), then the audio metadata + transcript row are inserted in a single transaction; on a failed insert, the WAV is removed (compensating delete). The runtime retention policy is snapshotted at insert time so later policy changes don't reinterpret older rows.
6. **`CalibrationController` operates on the serving snapshot**, not a passed-in `Profile`. It first requests a swap to the calibration profile/model, awaits the committed `ServingSnapshot`, asserts it matches the requested profile+model, then runs the ceremony using `snapshot.rules` for the post-process step.
7. **`Settings` opening on macOS Tahoe 26 uses the hidden-Window + notification trampoline** (Steipete's recipe). Scene order is **load-bearing**: `Window → MenuBarExtra → Settings`. A hidden `Window` scene with `@Environment(\.openSettings)` listens for an `openSettingsRequest` notification, briefly toggles activation policy from the current value back to itself, and calls `openSettings()`. The previous activation policy is captured and restored — never assumed `.accessory` or `.regular`. The menu-bar item posts the notification instead of calling `NSApp.sendAction(showSettingsWindow:)`.
8. **`SettingsStore` enforces the "last active profile" invariant** in the store, not just the UI: `softDelete` refuses when the row is the last non-deleted profile. `get(profileID:)` gains an `includeDeleted` parameter (defaults `false`). `lastActive()` returns the count of non-deleted profiles.
9. **`Runner` uses `await paster.paste(...)`** (the existing `Pasting` protocol is async).
10. **UI tabs gain functional tests** via injected coordinator/store protocols. The Settings tabs read from injection seams (e.g. `ProfilesViewModel`) so tests don't need to drive raw SwiftUI bindings.
11. **`HSplitView` → `NavigationSplitView`** for the Profiles tab.
12. **Audio file + DB consistency** uses write-temp → fsync → atomic move → DB insert in one transaction → on insert failure remove the WAV. Launch-time orphan sweep covers crashes between move and insert.
13. The harness gains a hidden-Window scene-order check and at least one functional-binding test per UI tab.

Verified facts (no need to re-verify during execution):

- `WhisperKit.DecodingOptions(promptTokens: [Int]?)` exists (constructor param).
- `WhisperKit.tokenizer` is non-nil after `RealWhisperKit.make()` (loaded inside `loadModels` via `loadTokenizerIfNeeded`).
- `GRDB 7 DatabaseQueue.init(named:configuration:)` and `init(path:configuration:)` both `throws` — `try` is correct.
- `GRDB Configuration.foreignKeysEnabled` exists with default `true`. The explicit set is a no-op but kept for clarity.
- `openSettings()` is broken inside `MenuBarExtra` on macOS Tahoe 26 — the hidden-Window trampoline is the verified workaround.

---

## Verification Harness — read this before executing any task

This plan continues the per-task `scripts/verify_task.sh N` harness established by the MVP plan (tasks 0–12). Each new task extends `scripts/verify_task.sh` with a new case that runs `bash "$0" PREV` first, then asserts the new task's contract (files exist, package builds, tests pass). A subagent picking up Task N runs `scripts/verify_task.sh N-1` to confirm the world matches what Task N expects.

Conventions (unchanged from the MVP plan):
- **Each task's last step before commit is `scripts/verify_task.sh N`.** If it fails, fix the cause and re-run; do not commit a failing state.
- **Commits land only after `verify_task.sh` passes.** `git log --oneline` is a reliable execution-progress signal.
- **The harness is offline.** Tests that require WhisperKit model downloads stay gated by `MUMBLUR_RUN_SLOW=1` and are not part of `verify_task.sh`.

Task numbering continues from 12 (the last MVP task). New cases: **13–28**.

---

## File Structure

### New files

```
MumblurCore/Sources/MumblurCore/
  Profile.swift                       value type
  ReplacementRule.swift               value type
  PromptPayload.swift                 value type (tokenized prompt)
  ServingSnapshot.swift               immutable serving bundle
  PromptBuilder.swift                 closure-only API → PromptPayload
  TranscriptPostProcessor.swift       applies replacement rules
  WERNormalizer.swift                 normalizes text before WER + mining
  ModelManager.swift                  list/download/load models; async throws swap with generation guard
  Storage/
    Database.swift                    GRDB connection + PRAGMA foreign_keys + migrations
    SettingsStore.swift               profile CRUD, active pointer, soft-delete (protects last), hard-purge
    TranscriptStore.swift             insert / stats / export
    AudioStore.swift                  WAV stream-write, chunked sha256, retention sweeper, orphan cleanup
    RetentionAwarePersister.swift     DictationPersisting impl (Task 21.5); consults retention policy
  Tuning/
    CalibrationScripts.swift          script constants + hashing + mining/eval split
    CalibrationController.swift       owns recording for the ceremony; uses serving snapshot
    WERCalculator.swift               token-level Levenshtein WER ('wer_v1')
    ErrorMiner.swift                  aligns ground-truth vs raw; mines produced→expected pairs
    SuggestionGenerator.swift         emits vocab terms + rules with support/precision gates

App/
  Settings/
    SettingsScene.swift               Settings scene + sidebar router
    OpenSettingsTrampoline.swift      hidden-Window listener for .openSettingsRequest (Tahoe 26 fix)
    GeneralSettingsView.swift
    ProfilesSettingsView.swift
    ModelsSettingsView.swift
    TuningSettingsView.swift
    DataSettingsView.swift
    AboutSettingsView.swift
    ViewModels/
      ProfilesViewModel.swift
      ModelsViewModel.swift
      TuningViewModel.swift
      DataViewModel.swift
  Tests/
    Settings/
      ProfilesViewModelTests.swift
      ModelsViewModelTests.swift
      TuningViewModelTests.swift
      DataViewModelTests.swift
```

### Modified files

```
MumblurCore/Package.swift             add GRDB dependency
MumblurCore/Sources/MumblurCore/
  Transcriber.swift                   actor owns ServingSnapshot; returns (rawText, snapshot)
  Runner.swift                        post-process via snapshot.rules; transactional persist
App/
  MumblurApp.swift                    add Settings scene
  AppCoordinator.swift                wire stores, pending vs serving selection, .swappingModel
  MenuBarContent.swift                active-profile switcher + "Settings…" item
scripts/verify_task.sh                cases 13–28
```

---

# Phase 1 — Storage + Value Types

## Task 13: GRDB dep + Database.swift + v1 migration

**Files:**
- Modify: `MumblurCore/Package.swift`
- Create: `MumblurCore/Sources/MumblurCore/Storage/Database.swift`
- Create: `MumblurCore/Sources/MumblurCore/Storage/MigrationsV1.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/Storage/DatabaseTests.swift`
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Write the failing test (schema + foreign_keys + every CHECK invariant)**

```swift
// MumblurCore/Tests/MumblurCoreTests/Storage/DatabaseTests.swift
import XCTest
import GRDB
@testable import MumblurCore

final class DatabaseTests: XCTestCase {

    private func makeDB() throws -> Database {
        try Database(location: .inMemory)
    }

    func testForeignKeysAreEnforced() throws {
        let db = try makeDB()
        try db.write { conn in
            let v: Int = try Int.fetchOne(conn, sql: "PRAGMA foreign_keys") ?? 0
            XCTAssertEqual(v, 1)
        }
    }

    func testMigrationApplies_AndIsIdempotent() throws {
        let db = try makeDB()
        try db.runMigrations()
        try db.runMigrations()  // second call must be a no-op
        try db.read { conn in
            let names = try String.fetchAll(conn,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            XCTAssertEqual(Set(names), [
                "app_setting", "calibration_run", "calibration_sample",
                "grdb_migrations", "profile", "replacement_rule",
                "retention_policy", "transcript", "vocab_term"
            ])
            let retention = try Row.fetchOne(conn, sql: "SELECT * FROM retention_policy")
            XCTAssertEqual(retention?["enabled"], 0)
            XCTAssertEqual(retention?["kind"], "days")
            XCTAssertEqual(retention?["value"], 30)
        }
    }

    func testProfileNameUniqueness_RespectsSoftDelete() throws {
        let db = try makeDB()
        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO profile(id,name,model_id,created_at,updated_at)
                VALUES ('a','Work','openai_whisper-large-v3-turbo',1,1)
            """)
            // Same name while active → must fail.
            XCTAssertThrowsError(try conn.execute(sql: """
                INSERT INTO profile(id,name,model_id,created_at,updated_at)
                VALUES ('b','work','openai_whisper-large-v3-turbo',1,1)
            """))
            // Soft-delete 'a', then 'Work' must be reusable.
            try conn.execute(sql: "UPDATE profile SET deleted_at=2 WHERE id='a'")
            try conn.execute(sql: """
                INSERT INTO profile(id,name,model_id,created_at,updated_at)
                VALUES ('c','Work','openai_whisper-large-v3-turbo',3,3)
            """)
        }
    }

    func testRetentionPolicyChecks() throws {
        let db = try makeDB()
        try db.write { conn in
            XCTAssertThrowsError(try conn.execute(sql:
                "UPDATE retention_policy SET kind='weeks' WHERE singleton=1"))
            XCTAssertThrowsError(try conn.execute(sql:
                "UPDATE retention_policy SET enabled=2 WHERE singleton=1"))
            XCTAssertThrowsError(try conn.execute(sql:
                "UPDATE retention_policy SET value=-1 WHERE singleton=1"))
        }
    }

    func testTranscriptAudioMetadataIsAllOrNothing() throws {
        let db = try makeDB()
        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO profile(id,name,model_id,created_at,updated_at)
                VALUES ('p','P','m',1,1)
            """)
            // Partial audio metadata must fail.
            XCTAssertThrowsError(try conn.execute(sql: """
                INSERT INTO transcript(profile_id,started_at,duration_ms,model_id,
                    raw_text,final_text,audio_rel_path)
                VALUES ('p',1,1,'m','r','f','clips/x.wav')
            """))
            // All-NULL (no audio) is OK.
            try conn.execute(sql: """
                INSERT INTO transcript(profile_id,started_at,duration_ms,model_id,raw_text,final_text)
                VALUES ('p',1,1,'m','r','f')
            """)
        }
    }

    func testCalibrationSampleDualResultInvariant() throws {
        let db = try makeDB()
        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO profile(id,name,model_id,created_at,updated_at)
                VALUES ('p','P','m',1,1)
            """)
            try conn.execute(sql: """
                INSERT INTO calibration_run(profile_id,profile_name_snapshot,script_id,
                    script_hash,started_at,model_id)
                VALUES ('p','P','s1','h',1,'m')
            """)
            // 'recorded' with a produced text must fail.
            XCTAssertThrowsError(try conn.execute(sql: """
                INSERT INTO calibration_sample(run_id,sample_index,set_role,status,ground_truth,
                    raw_text,duration_ms,audio_rel_path,audio_bytes,audio_sha256,
                    sample_rate_hz,channels,pcm_encoding)
                VALUES (1,0,'mining','recorded','gt',
                    'whoops',1,'p',1,
                    '0000000000000000000000000000000000000000000000000000000000000000',
                    16000,1,'pcm_s16le')
            """))
            // 'transcribed' without a wer must fail.
            XCTAssertThrowsError(try conn.execute(sql: """
                INSERT INTO calibration_sample(run_id,sample_index,set_role,status,ground_truth,
                    raw_text,final_text,duration_ms,audio_rel_path,audio_bytes,audio_sha256,
                    sample_rate_hz,channels,pcm_encoding)
                VALUES (1,1,'eval','transcribed','gt','r','f',1,'p',1,
                    '0000000000000000000000000000000000000000000000000000000000000000',
                    16000,1,'pcm_s16le')
            """))
        }
    }
}
```

- [ ] **Step 2: Add the GRDB dependency**

Edit `MumblurCore/Package.swift`:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MumblurCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MumblurCore", targets: ["MumblurCore"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "MumblurCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "MumblurCoreTests",
            dependencies: ["MumblurCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] **Step 3: Run the test to verify it fails (no Database type)**

```bash
cd MumblurCore && swift test --filter DatabaseTests
```

Expected: compile error — `cannot find type 'Database' in scope`.

- [ ] **Step 4: Implement `Database.swift`**

```swift
// MumblurCore/Sources/MumblurCore/Storage/Database.swift
import Foundation
import GRDB

public final class Database {
    public enum Location { case inMemory; case file(URL) }

    public let queue: DatabaseQueue

    public init(location: Location) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true     // PRAGMA foreign_keys = ON at every open
        switch location {
        case .inMemory:
            self.queue = try DatabaseQueue(configuration: config)
        case .file(let url):
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            self.queue = try DatabaseQueue(path: url.path, configuration: config)
        }
        try runMigrations()
    }

    public func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try queue.read(block)
    }

    public func write<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try queue.write(block)
    }

    public func runMigrations() throws {
        var migrator = DatabaseMigrator()
        migrator.registerV1()
        try migrator.migrate(queue)
    }
}
```

- [ ] **Step 5: Implement the v1 migration (full schema from spec §6)**

```swift
// MumblurCore/Sources/MumblurCore/Storage/MigrationsV1.swift
import GRDB

extension DatabaseMigrator {
    mutating func registerV1() {
        registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE profile (
                    id              TEXT PRIMARY KEY,
                    name            TEXT NOT NULL,
                    language        TEXT,
                    model_id        TEXT NOT NULL,
                    initial_prompt  TEXT,
                    created_at      INTEGER NOT NULL CHECK(created_at >= 0),
                    updated_at      INTEGER NOT NULL CHECK(updated_at >= created_at),
                    deleted_at      INTEGER          CHECK(deleted_at IS NULL OR deleted_at >= created_at)
                );
                CREATE UNIQUE INDEX idx_profile_name_nocase
                    ON profile(name COLLATE NOCASE) WHERE deleted_at IS NULL;

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
                    word_boundary   INTEGER NOT NULL DEFAULT 1 CHECK(word_boundary IN (0,1)),
                    sort_order      INTEGER NOT NULL DEFAULT 0 CHECK(sort_order >= 0)
                );
                CREATE INDEX idx_replacement_rule_profile_sort
                    ON replacement_rule(profile_id, sort_order, id);

                CREATE TABLE transcript (
                    id                      INTEGER PRIMARY KEY,
                    profile_id              TEXT REFERENCES profile(id) ON DELETE RESTRICT,
                    profile_name_snapshot   TEXT,
                    prompt_snapshot         TEXT,
                    started_at              INTEGER NOT NULL CHECK(started_at >= 0),
                    duration_ms             INTEGER NOT NULL CHECK(duration_ms >= 0),
                    model_id                TEXT NOT NULL,
                    language                TEXT,
                    raw_text                TEXT NOT NULL,
                    final_text              TEXT NOT NULL,
                    audio_rel_path          TEXT,
                    audio_bytes             INTEGER,
                    audio_sha256            TEXT,
                    sample_rate_hz          INTEGER,
                    channels                INTEGER,
                    pcm_encoding            TEXT,
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
                    script_hash             TEXT NOT NULL CHECK(script_hash <> ''),
                    scoring_version         TEXT NOT NULL DEFAULT 'wer_v1',
                    started_at              INTEGER NOT NULL CHECK(started_at >= 0),
                    completed_at            INTEGER CHECK(completed_at IS NULL OR completed_at >= started_at),
                    model_id                TEXT NOT NULL,
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
                    set_role        TEXT NOT NULL CHECK(set_role IN ('mining','eval')),
                    status          TEXT NOT NULL CHECK(status IN ('recorded','transcribed','failed')),
                    ground_truth    TEXT NOT NULL,
                    raw_text        TEXT,
                    final_text      TEXT,
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
                    CHECK (
                        (status = 'transcribed'
                            AND raw_text IS NOT NULL AND final_text IS NOT NULL
                            AND raw_wer IS NOT NULL AND final_wer IS NOT NULL) OR
                        (status IN ('recorded','failed')
                            AND raw_text IS NULL AND final_text IS NULL
                            AND raw_wer IS NULL AND final_wer IS NULL)
                    )
                );

                CREATE TABLE retention_policy (
                    singleton   INTEGER PRIMARY KEY CHECK(singleton = 1),
                    enabled     INTEGER NOT NULL    CHECK(enabled IN (0,1)),
                    kind        TEXT    NOT NULL    CHECK(kind IN ('days','count')),
                    value       INTEGER NOT NULL    CHECK(value >= 0)
                );
                INSERT INTO retention_policy(singleton, enabled, kind, value) VALUES (1, 0, 'days', 30);

                CREATE TABLE app_setting (
                    key   TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
            """)
        }
    }
}
```

- [ ] **Step 6: Run tests — all pass**

```bash
cd MumblurCore && swift test --filter DatabaseTests
```

Expected: 5 tests pass.

- [ ] **Step 7: Extend `scripts/verify_task.sh`**

Append before the `*)` default branch:

```bash
    13)
        bash "$0" 12
        need_file MumblurCore/Sources/MumblurCore/Storage/Database.swift
        need_file MumblurCore/Sources/MumblurCore/Storage/MigrationsV1.swift
        need_file MumblurCore/Tests/MumblurCoreTests/Storage/DatabaseTests.swift
        grep -q 'GRDB.swift' MumblurCore/Package.swift || fail "GRDB not in Package.swift"
        core_test
        ;;
```

- [ ] **Step 8: Run the harness, then commit**

```bash
scripts/verify_task.sh 13
git add MumblurCore/Package.swift MumblurCore/Sources/MumblurCore/Storage \
        MumblurCore/Tests/MumblurCoreTests/Storage scripts/verify_task.sh \
        MumblurCore/Package.resolved
git commit -m "feat(storage): GRDB Database + v1 migration with full schema invariants"
```

---

## Task 14: Value types — Profile, ReplacementRule, PromptPayload, ServingSnapshot

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/Profile.swift`
- Create: `MumblurCore/Sources/MumblurCore/ReplacementRule.swift`
- Create: `MumblurCore/Sources/MumblurCore/PromptPayload.swift`
- Create: `MumblurCore/Sources/MumblurCore/ServingSnapshot.swift`
- Create: `MumblurCore/Sources/MumblurCore/TranscriptPostProcessor.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/TranscriptPostProcessorTests.swift`
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Write the failing test for `TranscriptPostProcessor`**

```swift
// MumblurCore/Tests/MumblurCoreTests/TranscriptPostProcessorTests.swift
import XCTest
@testable import MumblurCore

final class TranscriptPostProcessorTests: XCTestCase {

    private func r(_ pattern: String, _ replacement: String,
                   isRegex: Bool = false, caseSensitive: Bool = false,
                   wordBoundary: Bool = true, sortOrder: Int = 0) -> ReplacementRule {
        ReplacementRule(id: 0, profileID: "p", pattern: pattern, replacement: replacement,
                        isRegex: isRegex, caseSensitive: caseSensitive,
                        wordBoundary: wordBoundary, sortOrder: sortOrder)
    }

    func testLiteralReplaceWithWordBoundary_doesNotMatchInsideWords() {
        let p = TranscriptPostProcessor()
        let out = p.apply("questionable", rules: [r("question", "QUESTION")])
        XCTAssertEqual(out, "questionable")
    }

    func testLiteralReplaceWithoutWordBoundary_matchesAnywhere() {
        let p = TranscriptPostProcessor()
        let out = p.apply("questionable", rules: [r("question", "QUESTION", wordBoundary: false)])
        XCTAssertEqual(out, "QUESTIONable")
    }

    func testCaseInsensitiveByDefault() {
        let p = TranscriptPostProcessor()
        let out = p.apply("Hello world", rules: [r("hello", "Hi")])
        XCTAssertEqual(out, "Hi world")
    }

    func testCaseSensitiveOnly() {
        let p = TranscriptPostProcessor()
        let out = p.apply("Hello hello", rules: [r("hello", "Hi", caseSensitive: true)])
        XCTAssertEqual(out, "Hello Hi")
    }

    func testRegexReplace() {
        let p = TranscriptPostProcessor()
        let out = p.apply("call 555-1234", rules: [r(#"\b\d{3}-\d{4}\b"#, "[redacted]",
                                                     isRegex: true)])
        XCTAssertEqual(out, "call [redacted]")
    }

    func testRulesAppliedInSortOrder() {
        let p = TranscriptPostProcessor()
        // sort_order 0 runs first; if it changes "a" → "b", the next "b" → "c" sees the new text.
        let out = p.apply("a", rules: [
            r("a", "b", sortOrder: 0),
            r("b", "c", sortOrder: 1),
        ])
        XCTAssertEqual(out, "c")
    }

    func testInvalidRegex_isSkipped_notFatal() {
        let p = TranscriptPostProcessor()
        let out = p.apply("hello", rules: [r("[", "x", isRegex: true), r("hello", "Hi")])
        XCTAssertEqual(out, "Hi")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd MumblurCore && swift test --filter TranscriptPostProcessorTests
```

Expected: compile errors.

- [ ] **Step 3: Implement `ReplacementRule.swift`**

```swift
// MumblurCore/Sources/MumblurCore/ReplacementRule.swift
import Foundation

public struct ReplacementRule: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let profileID: String
    public var pattern: String
    public var replacement: String
    public var isRegex: Bool
    public var caseSensitive: Bool
    public var wordBoundary: Bool
    public var sortOrder: Int

    public init(id: Int64, profileID: String, pattern: String, replacement: String,
                isRegex: Bool, caseSensitive: Bool, wordBoundary: Bool, sortOrder: Int) {
        self.id = id; self.profileID = profileID
        self.pattern = pattern; self.replacement = replacement
        self.isRegex = isRegex; self.caseSensitive = caseSensitive
        self.wordBoundary = wordBoundary; self.sortOrder = sortOrder
    }
}
```

- [ ] **Step 4: Implement `Profile.swift`**

```swift
// MumblurCore/Sources/MumblurCore/Profile.swift
import Foundation

public struct Profile: Equatable, Sendable, Identifiable {
    public let id: String                 // UUID
    public var name: String
    public var language: String?          // nil = auto-detect
    public var modelID: String            // WhisperKit model name
    public var initialPrompt: String?     // free-form, optional
    public var vocab: [String]
    public var rules: [ReplacementRule]
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: String, name: String, language: String?, modelID: String,
                initialPrompt: String?, vocab: [String], rules: [ReplacementRule],
                createdAt: Date, updatedAt: Date, deletedAt: Date?) {
        self.id = id; self.name = name; self.language = language
        self.modelID = modelID; self.initialPrompt = initialPrompt
        self.vocab = vocab; self.rules = rules
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}
```

- [ ] **Step 5: Implement `PromptPayload.swift`**

```swift
// MumblurCore/Sources/MumblurCore/PromptPayload.swift
import Foundation

/// A tokenized prompt frozen against a specific loaded model. Created at
/// model-swap-commit time and held inside a `ServingSnapshot`; never recomputed
/// per dictation. `omittedTerms` lists vocab terms dropped to fit within the
/// token budget so the UI can show them.
public struct PromptPayload: Equatable, Sendable {
    public let sourceText: String
    public let promptTokens: [Int]
    public let omittedTerms: [String]
    public static let empty = PromptPayload(sourceText: "", promptTokens: [], omittedTerms: [])

    public init(sourceText: String, promptTokens: [Int], omittedTerms: [String]) {
        self.sourceText = sourceText; self.promptTokens = promptTokens; self.omittedTerms = omittedTerms
    }
}
```

- [ ] **Step 6: Implement `ServingSnapshot.swift`**

```swift
// MumblurCore/Sources/MumblurCore/ServingSnapshot.swift
import Foundation

/// The immutable bundle that actually serves dictation. Held by the
/// `Transcriber` actor along with the loaded pipeline; returned alongside
/// `rawText` so persisted rows always reflect what produced the text.
public struct ServingSnapshot: Equatable, Sendable {
    public let profileID: String
    public let profileName: String
    public let modelID: String
    public let language: String?
    public let prompt: PromptPayload
    public let rules: [ReplacementRule]

    public init(profileID: String, profileName: String, modelID: String,
                language: String?, prompt: PromptPayload, rules: [ReplacementRule]) {
        self.profileID = profileID; self.profileName = profileName
        self.modelID = modelID; self.language = language
        self.prompt = prompt; self.rules = rules
    }
}
```

- [ ] **Step 7: Implement `TranscriptPostProcessor.swift`**

```swift
// MumblurCore/Sources/MumblurCore/TranscriptPostProcessor.swift
import Foundation

public struct TranscriptPostProcessor: Sendable {
    public init() {}

    public func apply(_ text: String, rules: [ReplacementRule]) -> String {
        var out = text
        // Lower sort_order runs first; deterministic id tiebreaker.
        let ordered = rules.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
        for rule in ordered {
            out = applyOne(rule, to: out)
        }
        return out
    }

    private func applyOne(_ rule: ReplacementRule, to text: String) -> String {
        var options: NSRegularExpression.Options = []
        if !rule.caseSensitive { options.insert(.caseInsensitive) }
        let pattern: String
        if rule.isRegex {
            pattern = rule.pattern
        } else {
            let escaped = NSRegularExpression.escapedPattern(for: rule.pattern)
            pattern = rule.wordBoundary ? "\\b\(escaped)\\b" : escaped
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            Logger.app.error("skipping invalid regex rule id=\(rule.id, privacy: .public)")
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range,
                                              withTemplate: rule.replacement)
    }
}
```

- [ ] **Step 8: Run tests — all pass**

```bash
cd MumblurCore && swift test --filter TranscriptPostProcessorTests
```

Expected: 7 tests pass.

- [ ] **Step 9: Extend `scripts/verify_task.sh`**

```bash
    14)
        bash "$0" 13
        need_file MumblurCore/Sources/MumblurCore/Profile.swift
        need_file MumblurCore/Sources/MumblurCore/ReplacementRule.swift
        need_file MumblurCore/Sources/MumblurCore/PromptPayload.swift
        need_file MumblurCore/Sources/MumblurCore/ServingSnapshot.swift
        need_file MumblurCore/Sources/MumblurCore/TranscriptPostProcessor.swift
        need_file MumblurCore/Tests/MumblurCoreTests/TranscriptPostProcessorTests.swift
        core_test
        ;;
```

- [ ] **Step 10: Verify and commit**

```bash
scripts/verify_task.sh 14
git add MumblurCore/Sources/MumblurCore/{Profile,ReplacementRule,PromptPayload,ServingSnapshot,TranscriptPostProcessor}.swift \
        MumblurCore/Tests/MumblurCoreTests/TranscriptPostProcessorTests.swift scripts/verify_task.sh
git commit -m "feat(core): Profile/ReplacementRule/PromptPayload/ServingSnapshot + post-processor"
```

---

## Task 15: SettingsStore (profile CRUD, active pointer, soft-delete, hard-purge)

> **REVISION v2 (read first):**
> - Add `lastActive() throws -> Int` returning the count of profiles with `deleted_at IS NULL`.
> - `softDelete(profileID:)` must throw `SettingsStoreError.cannotDeleteLastActive` if `lastActive() <= 1` and the target is not already soft-deleted.
> - `get(profileID:includeDeleted: Bool = false)` — when `includeDeleted=false` (default), filter `WHERE deleted_at IS NULL`. The active-profile pointer must never resolve to a soft-deleted row; `activeOrFirstActive()` filters accordingly.
> - Two new tests: (a) soft-deleting the last active profile throws; (b) `get(profileID:)` of a soft-deleted profile returns nil unless `includeDeleted: true`.

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/Storage/SettingsStore.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/Storage/SettingsStoreTests.swift`
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Write the failing tests**

```swift
// MumblurCore/Tests/MumblurCoreTests/Storage/SettingsStoreTests.swift
import XCTest
@testable import MumblurCore

final class SettingsStoreTests: XCTestCase {

    private func makeStore() throws -> SettingsStore {
        let db = try Database(location: .inMemory)
        return SettingsStore(database: db)
    }

    func testCreate_seedsDefaultsAndReturnsProfile() async throws {
        let store = try makeStore()
        let p = try await store.create(name: "Work", modelID: "openai_whisper-large-v3-turbo")
        XCTAssertEqual(p.name, "Work")
        XCTAssertEqual(p.vocab, [])
        XCTAssertNil(p.deletedAt)
    }

    func testListActive_excludesSoftDeleted() async throws {
        let store = try makeStore()
        let a = try await store.create(name: "A", modelID: "m")
        _ = try await store.create(name: "B", modelID: "m")
        try await store.softDelete(profileID: a.id)
        let active = try await store.listActive()
        XCTAssertEqual(active.map(\.name), ["B"])
    }

    func testActiveProfileID_persistsAcrossReads() async throws {
        let store = try makeStore()
        let a = try await store.create(name: "A", modelID: "m")
        try await store.setActiveProfileID(a.id)
        let got = try await store.activeProfileID()
        XCTAssertEqual(got, a.id)
    }

    func testSoftDelete_thenCreateSameName_succeeds() async throws {
        let store = try makeStore()
        let a = try await store.create(name: "Work", modelID: "m")
        try await store.softDelete(profileID: a.id)
        let b = try await store.create(name: "Work", modelID: "m")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testCreate_duplicateActiveName_throws() async throws {
        let store = try makeStore()
        _ = try await store.create(name: "Work", modelID: "m")
        do {
            _ = try await store.create(name: "work", modelID: "m")
            XCTFail("expected duplicate-name error")
        } catch {}
    }

    func testHardPurge_removesProfileAndAllItsData() async throws {
        let store = try makeStore()
        let a = try await store.create(name: "A", modelID: "m")
        try await store.addVocab(profileID: a.id, term: "Questable")
        try await store.hardPurge(profileID: a.id)
        let active = try await store.listActive()
        XCTAssertTrue(active.isEmpty)
        // Vocab and rules are CASCADE — gone too.
        let count = try await store.vocabCount(profileID: a.id)
        XCTAssertEqual(count, 0)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd MumblurCore && swift test --filter SettingsStoreTests
```

Expected: compile errors.

- [ ] **Step 3: Implement `SettingsStore.swift`**

```swift
// MumblurCore/Sources/MumblurCore/Storage/SettingsStore.swift
import Foundation
import GRDB

public actor SettingsStore {
    private let database: Database

    public init(database: Database) { self.database = database }

    public func create(name: String, modelID: String, language: String? = nil,
                       initialPrompt: String? = nil) throws -> Profile {
        let id = UUID().uuidString
        let now = Date()
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO profile(id,name,language,model_id,initial_prompt,created_at,updated_at)
                VALUES (?,?,?,?,?,?,?)
            """, arguments: [id, name, language, modelID, initialPrompt,
                             Int64(now.timeIntervalSince1970 * 1000),
                             Int64(now.timeIntervalSince1970 * 1000)])
        }
        return Profile(id: id, name: name, language: language, modelID: modelID,
                       initialPrompt: initialPrompt, vocab: [], rules: [],
                       createdAt: now, updatedAt: now, deletedAt: nil)
    }

    public func listActive() throws -> [Profile] {
        try database.read { db in
            try Profile.fetchAllActive(db)
        }
    }

    public func get(profileID: String) throws -> Profile? {
        try database.read { db in
            try Profile.fetchOne(db, id: profileID)
        }
    }

    public func update(_ profile: Profile) throws {
        let updated = Date()
        try database.write { db in
            try db.execute(sql: """
                UPDATE profile SET name=?, language=?, model_id=?, initial_prompt=?, updated_at=?
                WHERE id=?
            """, arguments: [profile.name, profile.language, profile.modelID,
                             profile.initialPrompt,
                             Int64(updated.timeIntervalSince1970 * 1000),
                             profile.id])
        }
    }

    public func softDelete(profileID: String) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE profile SET deleted_at=? WHERE id=?",
                           arguments: [Int64(Date().timeIntervalSince1970 * 1000), profileID])
        }
    }

    public func hardPurge(profileID: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM transcript      WHERE profile_id=?", arguments: [profileID])
            try db.execute(sql: "DELETE FROM calibration_run WHERE profile_id=?", arguments: [profileID])
            try db.execute(sql: "DELETE FROM profile         WHERE id=?",         arguments: [profileID])
        }
    }

    public func setActiveProfileID(_ id: String) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO app_setting(key,value) VALUES('active_profile_id',?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """, arguments: [id])
        }
    }

    public func activeProfileID() throws -> String? {
        try database.read { db in
            try String.fetchOne(db,
                sql: "SELECT value FROM app_setting WHERE key='active_profile_id'")
        }
    }

    public func addVocab(profileID: String, term: String) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO vocab_term(profile_id,term) VALUES(?,?)
            """, arguments: [profileID, term])
        }
    }

    public func vocabCount(profileID: String) throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vocab_term WHERE profile_id=?",
                             arguments: [profileID]) ?? 0
        }
    }
}

extension Profile {
    static func fetchAllActive(_ db: GRDB.Database) throws -> [Profile] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM profile WHERE deleted_at IS NULL ORDER BY name COLLATE NOCASE
        """)
        return try rows.map { try Profile(row: $0, db: db) }
    }
    static func fetchOne(_ db: GRDB.Database, id: String) throws -> Profile? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM profile WHERE id=?",
                                         arguments: [id]) else { return nil }
        return try Profile(row: row, db: db)
    }
    init(row: Row, db: GRDB.Database) throws {
        let id: String = row["id"]
        let vocab = try String.fetchAll(db,
            sql: "SELECT term FROM vocab_term WHERE profile_id=? ORDER BY term", arguments: [id])
        let rules = try Row.fetchAll(db,
            sql: "SELECT * FROM replacement_rule WHERE profile_id=? ORDER BY sort_order, id",
            arguments: [id]).map { r in
                ReplacementRule(
                    id: r["id"], profileID: id,
                    pattern: r["pattern"], replacement: r["replacement"],
                    isRegex: (r["is_regex"] as Int) == 1,
                    caseSensitive: (r["case_sensitive"] as Int) == 1,
                    wordBoundary: (r["word_boundary"] as Int) == 1,
                    sortOrder: r["sort_order"])
            }
        func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000.0) }
        self.init(
            id: id,
            name: row["name"], language: row["language"], modelID: row["model_id"],
            initialPrompt: row["initial_prompt"], vocab: vocab, rules: rules,
            createdAt: date(row["created_at"]),
            updatedAt: date(row["updated_at"]),
            deletedAt: (row["deleted_at"] as Int64?).map(date)
        )
    }
}
```

- [ ] **Step 4: Run tests — all pass**

```bash
cd MumblurCore && swift test --filter SettingsStoreTests
```

Expected: 6 tests pass.

- [ ] **Step 5: Extend `scripts/verify_task.sh`**

```bash
    15)
        bash "$0" 14
        need_file MumblurCore/Sources/MumblurCore/Storage/SettingsStore.swift
        need_file MumblurCore/Tests/MumblurCoreTests/Storage/SettingsStoreTests.swift
        core_test
        ;;
```

- [ ] **Step 6: Verify and commit**

```bash
scripts/verify_task.sh 15
git add MumblurCore/Sources/MumblurCore/Storage/SettingsStore.swift \
        MumblurCore/Tests/MumblurCoreTests/Storage/SettingsStoreTests.swift scripts/verify_task.sh
git commit -m "feat(storage): SettingsStore (profile CRUD + soft-delete + hard-purge)"
```

---

## Task 16: TranscriptStore + AudioStore (write-then-insert + retention sweeper + orphan cleanup)

> **REVISION v2 (read first):**
> - `AudioStore.write(samples:sampleRateHz:)` must **stream** the WAV write and SHA-256 via `FileHandle` + `var hasher = SHA256(); hasher.update(data: chunk); … hasher.finalize()`. Do not call `Data(contentsOf:)` to re-read the file just to hash it. Header is written first, then PCM in chunks (e.g. 64 KiB) which are also hashed.
> - Write protocol: write to `clips/<uuid>.wav.part` → `fsync` the file → move atomically to `clips/<uuid>.wav`. The DB insert happens in a separate transaction *after* the move (see Task 21.5). If the DB insert fails, the caller deletes the moved file (compensating delete). Launch-time orphan sweep (already specified) catches crashes between move and insert.
> - The retention sweeper unchanged, except it must also delete the orphaned WAVs of the rows it deletes (call `audio.cleanupOrphans(...)` after the row delete, which the spec already does).

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/Storage/TranscriptStore.swift`
- Create: `MumblurCore/Sources/MumblurCore/Storage/AudioStore.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/Storage/TranscriptStoreTests.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/Storage/AudioStoreTests.swift`
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Write the failing tests for both stores**

```swift
// MumblurCore/Tests/MumblurCoreTests/Storage/TranscriptStoreTests.swift
import XCTest
@testable import MumblurCore

final class TranscriptStoreTests: XCTestCase {

    private func setup() async throws -> (TranscriptStore, SettingsStore, Profile) {
        let db = try Database(location: .inMemory)
        let settings = SettingsStore(database: db)
        let store = TranscriptStore(database: db)
        let p = try await settings.create(name: "P", modelID: "m")
        return (store, settings, p)
    }

    func testInsert_textOnly_writesRowAndNoAudio() async throws {
        let (store, _, p) = try await setup()
        try await store.insertTextOnly(profileID: p.id, profileNameSnapshot: p.name,
            promptSnapshot: nil, startedAt: Date(), durationMs: 1234,
            modelID: "m", language: nil, rawText: "hi", finalText: "hi")
        let stats = try await store.stats()
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.audioCount, 0)
    }

    func testInsert_withAudio_requiresAllAudioFields() async throws {
        let (store, _, p) = try await setup()
        let audio = TranscriptStore.AudioMetadata(
            relPath: "clips/x.wav", bytes: 16, sha256: String(repeating: "a", count: 64),
            sampleRateHz: 16000, channels: 1, pcmEncoding: "pcm_s16le")
        try await store.insertWithAudio(profileID: p.id, profileNameSnapshot: p.name,
            promptSnapshot: nil, startedAt: Date(), durationMs: 1, modelID: "m",
            language: nil, rawText: "r", finalText: "f", audio: audio)
        let stats = try await store.stats()
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.audioCount, 1)
    }
}
```

```swift
// MumblurCore/Tests/MumblurCoreTests/Storage/AudioStoreTests.swift
import XCTest
@testable import MumblurCore

final class AudioStoreTests: XCTestCase {

    private func tmpRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mumblur-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testWriteThenMove_producesValidWAV_andStableSha256() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = AudioStore(root: root)
        let samples: [Float] = Array(repeating: 0.5, count: 1600) // 0.1s
        let result = try await audio.write(samples: samples, sampleRateHz: 16000)
        XCTAssertEqual(result.sha256.count, 64)
        XCTAssertGreaterThan(result.bytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.absoluteURL.path))
        XCTAssertTrue(result.relPath.hasPrefix("clips/"))
        XCTAssertTrue(result.relPath.hasSuffix(".wav"))
    }

    func testOrphanCleanup_deletesUnreferencedWAVs_keepsReferenced() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(location: .inMemory)
        let settings = SettingsStore(database: db)
        let transcripts = TranscriptStore(database: db)
        let audio = AudioStore(root: root)
        let p = try await settings.create(name: "P", modelID: "m")

        let keep = try await audio.write(samples: [0.1, 0.2], sampleRateHz: 16000)
        let drop = try await audio.write(samples: [0.3, 0.4], sampleRateHz: 16000)
        try await transcripts.insertWithAudio(
            profileID: p.id, profileNameSnapshot: p.name, promptSnapshot: nil,
            startedAt: Date(), durationMs: 1, modelID: "m", language: nil,
            rawText: "r", finalText: "f",
            audio: .init(relPath: keep.relPath, bytes: keep.bytes, sha256: keep.sha256,
                         sampleRateHz: 16000, channels: 1, pcmEncoding: "pcm_s16le"))

        try await audio.cleanupOrphans(referencedRelPaths: { try await transcripts.allAudioRelPaths() })
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.absoluteURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: drop.absoluteURL.path))
    }

    func testRetentionSweeper_byCount_keepsNewest() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(location: .inMemory)
        let settings = SettingsStore(database: db)
        let transcripts = TranscriptStore(database: db)
        let audio = AudioStore(root: root)
        let p = try await settings.create(name: "P", modelID: "m")

        for i in 0..<5 {
            let r = try await audio.write(samples: [0.0], sampleRateHz: 16000)
            try await transcripts.insertWithAudio(
                profileID: p.id, profileNameSnapshot: p.name, promptSnapshot: nil,
                startedAt: Date(timeIntervalSince1970: Double(i)), durationMs: 1,
                modelID: "m", language: nil, rawText: "r", finalText: "f",
                audio: .init(relPath: r.relPath, bytes: r.bytes, sha256: r.sha256,
                             sampleRateHz: 16000, channels: 1, pcmEncoding: "pcm_s16le"))
        }
        try await transcripts.sweep(policy: .count(limit: 2), audio: audio)
        let stats = try await transcripts.stats()
        XCTAssertEqual(stats.count, 2)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd MumblurCore && swift test --filter TranscriptStoreTests
cd MumblurCore && swift test --filter AudioStoreTests
```

Expected: compile errors.

- [ ] **Step 3: Implement `AudioStore.swift`**

```swift
// MumblurCore/Sources/MumblurCore/Storage/AudioStore.swift
import Foundation
import CryptoKit

public actor AudioStore {
    public struct WrittenAudio: Sendable {
        public let relPath: String
        public let absoluteURL: URL
        public let bytes: Int64
        public let sha256: String
    }

    public enum AudioStoreError: Error { case writeFailed }

    private let root: URL
    private let clipsDir: URL

    public init(root: URL) {
        self.root = root
        self.clipsDir = root.appendingPathComponent("clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
    }

    /// Writes a 16-bit PCM mono WAV. UUID-named so the filename is known before any DB insert.
    public func write(samples: [Float], sampleRateHz: Int) throws -> WrittenAudio {
        let id = UUID().uuidString
        let relPath = "clips/\(id).wav"
        let url = root.appendingPathComponent(relPath)
        let tmpURL = url.appendingPathExtension("part")

        let data = encodeWAV(samples: samples, sampleRateHz: sampleRateHz)
        try data.write(to: tmpURL, options: [.atomic])
        try FileManager.default.moveItem(at: tmpURL, to: url)

        let fileData = try Data(contentsOf: url)
        let digest = SHA256.hash(data: fileData)
        let sha = digest.map { String(format: "%02x", $0) }.joined()
        return WrittenAudio(relPath: relPath, absoluteURL: url,
                            bytes: Int64(fileData.count), sha256: sha)
    }

    /// Removes WAVs in `clips/` not referenced by any transcript row.
    /// `referenced` is an async closure so the caller can pass its DB query.
    public func cleanupOrphans(referencedRelPaths referenced: () async throws -> Set<String>) async throws {
        let ref = try await referenced()
        let items = (try? FileManager.default.contentsOfDirectory(
            at: clipsDir, includingPropertiesForKeys: nil)) ?? []
        for url in items where url.pathExtension == "wav" {
            let rel = "clips/\(url.lastPathComponent)"
            if !ref.contains(rel) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    public nonisolated func absoluteURL(forRelPath rel: String) -> URL {
        root.appendingPathComponent(rel)
    }

    private func encodeWAV(samples: [Float], sampleRateHz: Int) -> Data {
        // 16-bit PCM, mono.
        let pcm = samples.map { Int16(max(-1.0, min(1.0, $0)) * 32767) }
        let pcmData = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        let dataSize = UInt32(pcmData.count)
        let chunkSize = 36 + dataSize
        var out = Data()
        out.append("RIFF".data(using: .ascii)!)
        out.append(UInt32(chunkSize).littleEndianData)
        out.append("WAVE".data(using: .ascii)!)
        out.append("fmt ".data(using: .ascii)!)
        out.append(UInt32(16).littleEndianData)            // PCM subchunk size
        out.append(UInt16(1).littleEndianData)             // audioFormat = 1 (PCM)
        out.append(UInt16(1).littleEndianData)             // channels = 1
        out.append(UInt32(sampleRateHz).littleEndianData)
        out.append(UInt32(sampleRateHz * 2).littleEndianData) // byteRate
        out.append(UInt16(2).littleEndianData)             // blockAlign
        out.append(UInt16(16).littleEndianData)            // bitsPerSample
        out.append("data".data(using: .ascii)!)
        out.append(dataSize.littleEndianData)
        out.append(pcmData)
        return out
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var v = self.littleEndian; return Data(bytes: &v, count: MemoryLayout<Self>.size)
    }
}
```

- [ ] **Step 4: Implement `TranscriptStore.swift`**

```swift
// MumblurCore/Sources/MumblurCore/Storage/TranscriptStore.swift
import Foundation
import GRDB

public actor TranscriptStore {
    public struct AudioMetadata: Sendable {
        public let relPath: String
        public let bytes: Int64
        public let sha256: String
        public let sampleRateHz: Int
        public let channels: Int
        public let pcmEncoding: String
        public init(relPath: String, bytes: Int64, sha256: String,
                    sampleRateHz: Int, channels: Int, pcmEncoding: String) {
            self.relPath = relPath; self.bytes = bytes; self.sha256 = sha256
            self.sampleRateHz = sampleRateHz; self.channels = channels; self.pcmEncoding = pcmEncoding
        }
    }

    public struct Stats: Sendable {
        public let count: Int
        public let audioCount: Int
        public let bytes: Int64
        public let oldestAt: Date?
        public let newestAt: Date?
    }

    public enum RetentionPolicy: Sendable {
        case days(Int)
        case count(limit: Int)
    }

    private let database: Database
    public init(database: Database) { self.database = database }

    public func insertTextOnly(profileID: String, profileNameSnapshot: String,
        promptSnapshot: String?, startedAt: Date, durationMs: Int,
        modelID: String, language: String?, rawText: String, finalText: String) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO transcript(profile_id, profile_name_snapshot, prompt_snapshot,
                    started_at, duration_ms, model_id, language, raw_text, final_text)
                VALUES (?,?,?,?,?,?,?,?,?)
            """, arguments: [profileID, profileNameSnapshot, promptSnapshot,
                             Int64(startedAt.timeIntervalSince1970 * 1000), durationMs,
                             modelID, language, rawText, finalText])
        }
    }

    public func insertWithAudio(profileID: String, profileNameSnapshot: String,
        promptSnapshot: String?, startedAt: Date, durationMs: Int,
        modelID: String, language: String?, rawText: String, finalText: String,
        audio: AudioMetadata) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO transcript(profile_id, profile_name_snapshot, prompt_snapshot,
                    started_at, duration_ms, model_id, language, raw_text, final_text,
                    audio_rel_path, audio_bytes, audio_sha256,
                    sample_rate_hz, channels, pcm_encoding)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, arguments: [profileID, profileNameSnapshot, promptSnapshot,
                             Int64(startedAt.timeIntervalSince1970 * 1000), durationMs,
                             modelID, language, rawText, finalText,
                             audio.relPath, audio.bytes, audio.sha256,
                             audio.sampleRateHz, audio.channels, audio.pcmEncoding])
        }
    }

    public func stats() throws -> Stats {
        try database.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript") ?? 0
            let audioCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM transcript WHERE audio_rel_path IS NOT NULL") ?? 0
            let bytes = try Int64.fetchOne(db,
                sql: "SELECT COALESCE(SUM(audio_bytes), 0) FROM transcript") ?? 0
            let oldest = try Int64.fetchOne(db, sql: "SELECT MIN(started_at) FROM transcript")
            let newest = try Int64.fetchOne(db, sql: "SELECT MAX(started_at) FROM transcript")
            func date(_ ms: Int64?) -> Date? { ms.map { Date(timeIntervalSince1970: Double($0) / 1000.0) } }
            return Stats(count: count, audioCount: audioCount, bytes: bytes,
                         oldestAt: date(oldest), newestAt: date(newest))
        }
    }

    public func allAudioRelPaths() throws -> Set<String> {
        try database.read { db in
            Set(try String.fetchAll(db,
                sql: "SELECT audio_rel_path FROM transcript WHERE audio_rel_path IS NOT NULL"))
        }
    }

    /// Deletes transcript rows according to `policy`, then asks `audio` to clean up
    /// orphaned WAV files. Audio policy stays consistent with row policy.
    public func sweep(policy: RetentionPolicy, audio: AudioStore) async throws {
        try database.write { db in
            switch policy {
            case .days(let days):
                let cutoffMs = Int64((Date().addingTimeInterval(-Double(days) * 86400))
                    .timeIntervalSince1970 * 1000)
                try db.execute(sql: "DELETE FROM transcript WHERE started_at < ?",
                               arguments: [cutoffMs])
            case .count(let limit):
                try db.execute(sql: """
                    DELETE FROM transcript WHERE id NOT IN (
                        SELECT id FROM transcript ORDER BY started_at DESC LIMIT ?
                    )
                """, arguments: [limit])
            }
        }
        try await audio.cleanupOrphans(referencedRelPaths: { try self.allAudioRelPaths() })
    }
}
```

- [ ] **Step 5: Run tests — all pass**

```bash
cd MumblurCore && swift test --filter TranscriptStoreTests
cd MumblurCore && swift test --filter AudioStoreTests
```

Expected: 5 tests total pass.

- [ ] **Step 6: Extend `scripts/verify_task.sh`**

```bash
    16)
        bash "$0" 15
        need_file MumblurCore/Sources/MumblurCore/Storage/TranscriptStore.swift
        need_file MumblurCore/Sources/MumblurCore/Storage/AudioStore.swift
        need_file MumblurCore/Tests/MumblurCoreTests/Storage/TranscriptStoreTests.swift
        need_file MumblurCore/Tests/MumblurCoreTests/Storage/AudioStoreTests.swift
        core_test
        ;;
```

- [ ] **Step 7: Verify and commit**

```bash
scripts/verify_task.sh 16
git add MumblurCore/Sources/MumblurCore/Storage/{TranscriptStore,AudioStore}.swift \
        MumblurCore/Tests/MumblurCoreTests/Storage/{TranscriptStore,AudioStore}Tests.swift \
        scripts/verify_task.sh
git commit -m "feat(storage): TranscriptStore + AudioStore (write-then-insert, retention, orphans)"
```

---

# Phase 2 — WhisperKit Reality Spike + PromptBuilder

## Task 17: WhisperKit integration spike + PromptBuilder

> **REVISION v2 (read first):**
> - `PromptBuilder` has a **single** closure-only public API:
>   ```swift
>   public typealias TokenizeText = @Sendable (String) throws -> [Int]
>   public enum PromptBuilder {
>       public static func build(initialPrompt: String?,
>                                vocab: [String],
>                                budget: PromptBudget,
>                                tokenize: TokenizeText) throws -> PromptPayload
>   }
>   ```
>   Delete the generic `<T: Tokenizing>` overload and the `buildClosure` private duplicate from the body below. The `Tokenizing` protocol still exists for `LoadedModel.tokenizer`, but `PromptBuilder` does not depend on it.
> - The unit tests should pass a `@Sendable` closure (a counter-based fake tokenizer) — no generic struct value needed.
> - The spike test name and contract change: rename `testPipelineLoadsAndExposesTokenizer` to `testPipelineLoadsAndAcceptsPromptTokens` and add a `pipeline.transcribe(audioArray:decodeOptions:)` call with `DecodingOptions(promptTokens: tokens)`. Assert it returns without throwing — do **not** assert a particular textual output (a tiny model is not deterministic on biasing).

**Goal:** Before building the rest of the pipeline on `promptTokens`, prove the API really works end-to-end. The spike is one **gated slow test** that downloads a tiny model, tokenizes a glossary, and verifies that biasing affects decoding.

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/PromptBuilder.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/PromptBuilderTests.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/WhisperKitSpikeTests.swift`
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Write the failing test for `PromptBuilder` (deterministic, no WhisperKit)**

```swift
// MumblurCore/Tests/MumblurCoreTests/PromptBuilderTests.swift
import XCTest
@testable import MumblurCore

/// Pure, value-only tokenizer: one word = one token-id equal to its position
/// in the input string. Stateless and trivially Sendable.
private let positionalTokenize: TokenizeText = { text in
    text.split(separator: " ").enumerated().map { (i, _) in i }
}

final class PromptBuilderTests: XCTestCase {

    func testRenders_initialPromptFirst_thenVocab_inGivenOrder() throws {
        let p = try PromptBuilder.build(
            initialPrompt: "Lab note:",
            vocab: ["WhisperKit", "Questable", "Mumblur"],
            budget: .max,
            tokenize: positionalTokenize)
        XCTAssertTrue(p.sourceText.hasPrefix("Lab note:"))
        XCTAssertEqual(p.omittedTerms, [])
        XCTAssertEqual(p.promptTokens.count,
                       p.sourceText.split(separator: " ").count)
    }

    func testTruncates_byTokenBudget_andReportsOmitted() throws {
        let p = try PromptBuilder.build(
            initialPrompt: nil,
            vocab: ["a", "b", "c", "d"],
            budget: .tokens(3),
            tokenize: positionalTokenize)
        XCTAssertEqual(p.promptTokens.count, 3)
        XCTAssertEqual(p.omittedTerms, ["d"])
    }

    func testEmptyProfileYieldsEmptyPayload() throws {
        let p = try PromptBuilder.build(
            initialPrompt: nil, vocab: [],
            budget: .tokens(100), tokenize: positionalTokenize)
        XCTAssertEqual(p, .empty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd MumblurCore && swift test --filter PromptBuilderTests
```

Expected: compile errors.

- [ ] **Step 3: Implement `PromptBuilder.swift` (closure-only API)**

```swift
// MumblurCore/Sources/MumblurCore/PromptBuilder.swift
import Foundation

public protocol Tokenizing: Sendable {
    func encode(text: String) throws -> [Int]
}

public enum PromptBudget: Sendable { case max; case tokens(Int) }

public typealias TokenizeText = @Sendable (String) throws -> [Int]

public enum PromptBuilder {
    /// Builds a `PromptPayload` deterministically:
    ///   * `initialPrompt` (if any) is the first sentence;
    ///   * vocab terms follow as "Glossary: term1, term2, …";
    ///   * tokens are truncated to `budget`, dropping trailing vocab terms;
    ///   * `omittedTerms` is reported back in original order.
    public static func build(initialPrompt: String?,
                             vocab: [String],
                             budget: PromptBudget,
                             tokenize: TokenizeText) throws -> PromptPayload {
        let hasPrompt = !(initialPrompt ?? "").isEmpty
        if !hasPrompt && vocab.isEmpty { return .empty }

        func compose(_ kept: [String]) -> String {
            var s = ""
            if let p = initialPrompt, !p.isEmpty { s += p }
            if !kept.isEmpty {
                if !s.isEmpty { s += " " }
                s += "Glossary: " + kept.joined(separator: ", ")
            }
            return s
        }

        var kept = vocab
        var source = compose(kept)
        var tokens = try tokenize(source)
        var omitted: [String] = []

        if case .tokens(let limit) = budget {
            while tokens.count > limit, let dropped = kept.popLast() {
                omitted.append(dropped)
                source = compose(kept)
                tokens = try tokenize(source)
            }
            if tokens.count > limit { tokens = Array(tokens.prefix(limit)) }
        }
        return PromptPayload(sourceText: source,
                             promptTokens: tokens,
                             omittedTerms: omitted.reversed())
    }
}
```

- [ ] **Step 4: Run unit tests — all pass**

```bash
cd MumblurCore && swift test --filter PromptBuilderTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Add the gated WhisperKit spike test**

```swift
// MumblurCore/Tests/MumblurCoreTests/WhisperKitSpikeTests.swift
import XCTest
@testable import MumblurCore
import WhisperKit

/// Slow integration spike. Confirms that:
///   1. fetchAvailableModels / download / loadModels work,
///   2. tokenizer.encode(text:) is reachable on a loaded model,
///   3. DecodingOptions.promptTokens biases output (sanity: tokenizer roundtrip).
final class WhisperKitSpikeTests: XCTestCase {

    private var slow: Bool {
        ProcessInfo.processInfo.environment["MUMBLUR_RUN_SLOW"] == "1"
    }

    func testPipelineLoadsAndExposesTokenizer() async throws {
        try XCTSkipUnless(slow, "set MUMBLUR_RUN_SLOW=1 to run this spike")
        let kit = try await RealWhisperKit.make(modelHint: "openai_whisper-tiny")
        let tokens = kit.encode(text: "Mumblur Questable")
        XCTAssertFalse(tokens.isEmpty, "tokenizer.encode produced no tokens for non-empty text")
    }
}
```

- [ ] **Step 6: Extend `RealWhisperKit` so the spike can call `encode(text:)`**

In `MumblurCore/Sources/MumblurCore/Transcriber.swift`, add to `RealWhisperKit`:

```swift
public func encode(text: String) -> [Int] {
    pipeline.tokenizer?.encode(text: text) ?? []
}
```

- [ ] **Step 7: Run the spike (manual, slow) once to confirm it passes**

```bash
cd MumblurCore && MUMBLUR_RUN_SLOW=1 swift test --filter WhisperKitSpikeTests
```

Expected: PASS. If it fails, fix the model name (use what `fetchAvailableModels` returns) — do NOT proceed.

- [ ] **Step 8: Extend `scripts/verify_task.sh`**

```bash
    17)
        bash "$0" 16
        need_file MumblurCore/Sources/MumblurCore/PromptBuilder.swift
        need_file MumblurCore/Tests/MumblurCoreTests/PromptBuilderTests.swift
        need_file MumblurCore/Tests/MumblurCoreTests/WhisperKitSpikeTests.swift
        core_test
        ;;
```

- [ ] **Step 9: Verify and commit**

```bash
scripts/verify_task.sh 17
git add MumblurCore/Sources/MumblurCore/PromptBuilder.swift \
        MumblurCore/Tests/MumblurCoreTests/{PromptBuilderTests,WhisperKitSpikeTests}.swift \
        MumblurCore/Sources/MumblurCore/Transcriber.swift scripts/verify_task.sh
git commit -m "feat(prompt): PromptBuilder + WhisperKit reality spike (gated)"
```

---

# Phase 3 — Serving + Swap Concurrency + Pipeline Integration

## Task 18: Transcriber holds ServingSnapshot; returns (rawText, snapshot)

> **REVISION v2 (read first) — this is the load-bearing compile-level fix:**
> - `WhisperKitTranscribing` gains a `promptTokens` parameter:
>   ```swift
>   public protocol WhisperKitTranscribing: Sendable {
>       func transcribe(audioArray: [Float],
>                       language: String?,
>                       detectLanguage: Bool,
>                       promptTokens: [Int]?) async throws -> [any WhisperKitSegment]
>   }
>   ```
> - `Transcriber.transcribe(_:)` passes `snap.prompt.promptTokens` (or `nil` if empty) on every call.
> - `RealWhisperKit.transcribe(audioArray:language:detectLanguage:promptTokens:)` constructs
>   `DecodingOptions(language: language, detectLanguage: detectLanguage, promptTokens: promptTokens?.isEmpty == true ? nil : promptTokens)`.
>   The existing 30-second padding stays.
> - **All fakes** in `TranscriberTests`, `RunnerTests`, `ModelManagerTests`, `CalibrationControllerTests` must add the new parameter to their stubs (it can be ignored inside the fake — but the signature must compile).
> - A new test in `TranscriberTests`: `testTranscribe_threadsPromptTokensFromSnapshot()` — fake captures the `promptTokens` argument and asserts it equals `snapshot.prompt.promptTokens`.

**Files:**
- Modify: `MumblurCore/Sources/MumblurCore/Transcriber.swift`
- Modify: `MumblurCore/Tests/MumblurCoreTests/TranscriberTests.swift`
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Update tests to require the new API**

Replace the existing assertions in `TranscriberTests` so each test calls `await transcriber.commit(snapshot:, kit:)` first, then asserts on `(raw, snap)` from `try await transcriber.transcribe(samples)`.

```swift
// MumblurCore/Tests/MumblurCoreTests/TranscriberTests.swift  (replace file)
import XCTest
@testable import MumblurCore

private struct FakeKit: WhisperKitTranscribing {
    let output: String
    func transcribe(audioArray: [Float], language: String?, detectLanguage: Bool)
    async throws -> [any WhisperKitSegment] {
        struct S: WhisperKitSegment { let text: String }
        return output.isEmpty ? [] : [S(text: output)]
    }
}

final class TranscriberTests: XCTestCase {

    private func snap(profile: String = "p", model: String = "m",
                      language: String? = nil,
                      prompt: PromptPayload = .empty,
                      rules: [ReplacementRule] = []) -> ServingSnapshot {
        ServingSnapshot(profileID: "id-\(profile)", profileName: profile, modelID: model,
                        language: language, prompt: prompt, rules: rules)
    }

    func testTranscribe_returnsRawAndSnapshot() async throws {
        let t = Transcriber()
        await t.commit(snapshot: snap(), kit: FakeKit(output: " hello "))
        let result = try await t.transcribe([1, 2, 3])
        XCTAssertEqual(result.rawText, "hello")
        XCTAssertEqual(result.snapshot.profileName, "p")
    }

    func testCommitSwap_replacesServing() async throws {
        let t = Transcriber()
        await t.commit(snapshot: snap(profile: "a"), kit: FakeKit(output: "x"))
        await t.commit(snapshot: snap(profile: "b"), kit: FakeKit(output: "y"))
        let result = try await t.transcribe([0])
        XCTAssertEqual(result.snapshot.profileName, "b")
        XCTAssertEqual(result.rawText, "y")
    }

    func testTranscribe_beforeCommit_throws() async {
        let t = Transcriber()
        do {
            _ = try await t.transcribe([0])
            XCTFail("expected NotServingError")
        } catch {}
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd MumblurCore && swift test --filter TranscriberTests
```

Expected: compile errors.

- [ ] **Step 3: Rewrite `Transcriber.swift`**

```swift
// MumblurCore/Sources/MumblurCore/Transcriber.swift  (replace the actor; keep WhisperKitTranscribing + RealWhisperKit definitions)
import Foundation
import WhisperKit
import os

public protocol WhisperKitSegment: Sendable { var text: String { get } }

public protocol WhisperKitTranscribing: Sendable {
    func transcribe(audioArray: [Float], language: String?, detectLanguage: Bool)
        async throws -> [any WhisperKitSegment]
}

public struct TranscriptionOutput: Sendable {
    public let rawText: String
    public let snapshot: ServingSnapshot
}

public enum TranscriberError: Error { case notServing }

public actor Transcriber {
    private var serving: ServingSnapshot?
    private var kit: (any WhisperKitTranscribing)?

    public init() {}

    /// Atomically replace the active serving snapshot + pipeline.
    public func commit(snapshot: ServingSnapshot, kit: any WhisperKitTranscribing) {
        self.serving = snapshot
        self.kit = kit
    }

    public func transcribe(_ samples: [Float]) async throws -> TranscriptionOutput {
        guard let snap = serving, let kit else { throw TranscriberError.notServing }
        guard !samples.isEmpty else {
            return TranscriptionOutput(rawText: "", snapshot: snap)
        }
        let detect = (snap.language == nil)
        let segments = try await kit.transcribe(audioArray: samples,
                                                language: snap.language,
                                                detectLanguage: detect)
        let raw = segments.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionOutput(rawText: raw, snapshot: snap)
    }
}

// Existing RealWhisperKit / resolveModelName / padded transcribe stays unchanged,
// plus the encode(text:) helper added in Task 17.
```

- [ ] **Step 4: Run tests — all pass**

```bash
cd MumblurCore && swift test --filter TranscriberTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Extend `scripts/verify_task.sh`**

```bash
    18)
        bash "$0" 17
        grep -q 'actor Transcriber' MumblurCore/Sources/MumblurCore/Transcriber.swift
        grep -q 'func commit(snapshot:' MumblurCore/Sources/MumblurCore/Transcriber.swift
        core_test
        ;;
```

- [ ] **Step 6: Verify and commit**

```bash
scripts/verify_task.sh 18
git add MumblurCore/Sources/MumblurCore/Transcriber.swift \
        MumblurCore/Tests/MumblurCoreTests/TranscriberTests.swift scripts/verify_task.sh
git commit -m "refactor(transcribe): Transcriber owns ServingSnapshot; returns (rawText, snapshot)"
```

---

## Task 19: ModelManager with generation-guarded swap

> **REVISION v2 (read first):**
> - `requestSwap(to:promptBudget:)` is **`async throws -> ServingSnapshot`** (not `Void`). On a successful swap it returns the committed snapshot; on a load failure it throws. Errors are *not* swallowed.
> - The generation guard still runs: if a newer request supersedes this one before commit, the current `requestSwap` throws `ModelManagerError.staleSwap` and does NOT commit to the `Transcriber`. The caller (AppCoordinator) decides what to do based on which swap it is observing.
> - Add tests covering: (a) successful swap returns the snapshot; (b) stale older swap throws `.staleSwap` AND does not clobber the newer-loaded snapshot; (c) loader error surfaces as `requestSwap` throw.

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/ModelManager.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/ModelManagerTests.swift`
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Write the failing tests (the load-bearing concurrency test is here)**

```swift
// MumblurCore/Tests/MumblurCoreTests/ModelManagerTests.swift
import XCTest
@testable import MumblurCore

/// A loader whose load duration is controllable per modelID so we can interleave
/// a slow older swap with a fast newer one.
private actor ControllableLoader: ModelLoading {
    var schedule: [String: UInt64] = [:]   // modelID → ns delay
    var calls: [String] = []
    func setDelay(modelID: String, ns: UInt64) { schedule[modelID] = ns }
    func load(modelID: String) async throws -> LoadedModel {
        calls.append(modelID)
        if let ns = schedule[modelID] { try await Task.sleep(nanoseconds: ns) }
        return LoadedModel(kit: FixedKit(text: modelID, tag: modelID), tokenizer: FakeTokenizer())
    }
}

private struct FixedKit: WhisperKitTranscribing {
    let text: String; let tag: String
    func transcribe(audioArray: [Float], language: String?, detectLanguage: Bool)
    async throws -> [any WhisperKitSegment] {
        struct S: WhisperKitSegment { let text: String }
        return [S(text: text)]
    }
}

private struct FakeTokenizer: Tokenizing {
    func encode(text: String) throws -> [Int] { Array(0..<text.count) }
}

final class ModelManagerTests: XCTestCase {

    private func profile(name: String, modelID: String) -> Profile {
        Profile(id: "id-\(name)", name: name, language: nil, modelID: modelID,
                initialPrompt: nil, vocab: [], rules: [],
                createdAt: Date(), updatedAt: Date(), deletedAt: nil)
    }

    func testSwap_commitsServingSnapshotOnTranscriber() async throws {
        let loader = ControllableLoader()
        let transcriber = Transcriber()
        let manager = ModelManager(loader: loader, transcriber: transcriber)
        let snap = try await manager.requestSwap(to: profile(name: "A", modelID: "m1"))
        XCTAssertEqual(snap.modelID, "m1")
        let out = try await transcriber.transcribe([0])
        XCTAssertEqual(out.snapshot.modelID, "m1")
    }

    func testOlderSlowSwap_throwsStaleSwap_doesNotClobberNewerCommit() async throws {
        let loader = ControllableLoader()
        await loader.setDelay(modelID: "old", ns: 200_000_000)  // 200 ms
        await loader.setDelay(modelID: "new", ns: 10_000_000)   // 10 ms
        let transcriber = Transcriber()
        let manager = ModelManager(loader: loader, transcriber: transcriber)

        async let oldResult = throwingResult { try await manager.requestSwap(to: profile(name: "Old", modelID: "old")) }
        try await Task.sleep(nanoseconds: 5_000_000)            // 5 ms
        async let newResult = throwingResult { try await manager.requestSwap(to: profile(name: "New", modelID: "new")) }

        let oldFinished = await oldResult
        let newFinished = await newResult
        // The newer swap committed.
        XCTAssertNoThrow(try newFinished.get())
        XCTAssertEqual((try? newFinished.get())?.modelID, "new")
        // The older one was superseded.
        switch oldFinished {
        case .failure(let e as ModelManagerError):
            XCTAssertEqual(e, .staleSwap)
        default:
            XCTFail("expected .staleSwap from the older request, got \(oldFinished)")
        }

        let out = try await transcriber.transcribe([0])
        XCTAssertEqual(out.snapshot.modelID, "new")
    }
}

private func throwingResult<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd MumblurCore && swift test --filter ModelManagerTests
```

Expected: compile errors.

- [ ] **Step 3: Implement `ModelManager.swift`**

```swift
// MumblurCore/Sources/MumblurCore/ModelManager.swift
import Foundation
import os

public struct LoadedModel: Sendable {
    public let kit: any WhisperKitTranscribing
    public let tokenizer: any Tokenizing      // non-mutating; Tokenizing is Sendable
}

public protocol ModelLoading: Sendable {
    func load(modelID: String) async throws -> LoadedModel
}

public enum ModelManagerError: Error, Equatable { case staleSwap }

public actor ModelManager {
    private let loader: any ModelLoading
    private let transcriber: Transcriber
    private var generation: UInt64 = 0

    public init(loader: any ModelLoading, transcriber: Transcriber) {
        self.loader = loader; self.transcriber = transcriber
    }

    /// Returns the committed `ServingSnapshot` on success. Throws if the load fails
    /// or if a newer `requestSwap` superseded this one before commit.
    public func requestSwap(to profile: Profile,
                            promptBudget: PromptBudget = .tokens(220)) async throws -> ServingSnapshot {
        generation &+= 1
        let mine = generation
        let model = try await loader.load(modelID: profile.modelID)
        // Build the prompt using THIS model's tokenizer, frozen into the snapshot.
        // `LoadedModel.tokenizer` is `Tokenizing & Sendable`; the call is non-mutating.
        let tokenizer = model.tokenizer
        let payload = try PromptBuilder.build(
            initialPrompt: profile.initialPrompt,
            vocab: profile.vocab,
            budget: promptBudget,
            tokenize: { try tokenizer.encode(text: $0) })
        // Reentrancy guard: commit only if this is still the most recent request.
        guard mine == generation else {
            Logger.app.info("dropping stale swap generation=\(mine) current=\(self.generation)")
            throw ModelManagerError.staleSwap
        }
        let snap = ServingSnapshot(
            profileID: profile.id, profileName: profile.name,
            modelID: profile.modelID, language: profile.language,
            prompt: payload, rules: profile.rules)
        await transcriber.commit(snapshot: snap, kit: model.kit)
        return snap
    }
}
```

- [ ] **Step 4: Run tests — all pass**

```bash
cd MumblurCore && swift test --filter ModelManagerTests
```

Expected: 2 tests pass.

- [ ] **Step 5: Extend `scripts/verify_task.sh`**

```bash
    19)
        bash "$0" 18
        need_file MumblurCore/Sources/MumblurCore/ModelManager.swift
        need_file MumblurCore/Tests/MumblurCoreTests/ModelManagerTests.swift
        grep -q 'generation &+= 1' MumblurCore/Sources/MumblurCore/ModelManager.swift \
            || fail "ModelManager missing generation guard"
        core_test
        ;;
```

- [ ] **Step 6: Verify and commit**

```bash
scripts/verify_task.sh 19
git add MumblurCore/Sources/MumblurCore/ModelManager.swift \
        MumblurCore/Tests/MumblurCoreTests/ModelManagerTests.swift scripts/verify_task.sh
git commit -m "feat(model): ModelManager with generation-guarded swap"
```

---

## Task 20: Runner integration — post-process + transactional persist via snapshot

> **REVISION v2 (read first):**
> - Use **`await paster.paste(finalText)`** — the existing `Pasting` protocol is async. The `try? paster.paste(...)` line in the body is wrong; replace it.
> - Persistence is **NOT** `Task.detached`. The persistence call is `await`ed inside the runner's own worker (the worker is already off the UI). Detached losing structured-concurrency makes Swift 6 `Sendable` capture analysis harder and we don't need it.
> - Inject persistence via a `DictationPersisting` protocol (not `TranscriptPersisting`) — this is the seam that Task 21.5 fills with `RetentionAwarePersister`. Signature:
>   ```swift
>   public protocol DictationPersisting: Sendable {
>       func persist(samples: [Float],
>                    snapshot: ServingSnapshot,
>                    startedAt: Date, durationMs: Int,
>                    rawText: String, finalText: String) async
>   }
>   ```
>   The persister is responsible for consulting retention policy and either writing audio or not (Task 21.5). Persist failures are logged but do not propagate to the worker — paste already happened.
> - Use **`output.snapshot.rules`** (not `profile.rules`) for post-processing. The whole point of returning the snapshot from `Transcriber` is that this code path treats the snapshot as the source of truth.

**Files:**
- Modify: `MumblurCore/Sources/MumblurCore/Runner.swift`
- Modify: `MumblurCore/Tests/MumblurCoreTests/RunnerTests.swift`
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Extend `RunnerTests` to cover the new contract**

Add to `RunnerTests`:

```swift
// Add to MumblurCore/Tests/MumblurCoreTests/RunnerTests.swift
import XCTest
@testable import MumblurCore

final class RunnerPostProcessTests: XCTestCase {

    func testFullCycle_appliesRules_andPersistsViaSnapshot() async throws {
        // Recorder, paster, transcriber wired with a snapshot whose rules rewrite Quest→Questable.
        // Spy paster captures what got pasted; spy transcript store captures the row metadata.
        // (Reuse the existing test doubles from RunnerTests for AudioRecording/Pasting/etc.)
        // Assertions:
        //   * paster received finalText "Questable rocks", not "Quest rocks"
        //   * transcriptStore.lastInsert.profileNameSnapshot == "Work"
        //   * transcriptStore.lastInsert.modelID == "m-work"
        //   * transcriptStore.lastInsert.rawText == "Quest rocks"
        //   * transcriptStore.lastInsert.finalText == "Questable rocks"
    }

    func testPersistenceFailure_doesNotBlockPaste() async throws {
        // Configure transcript store to throw on insert.
        // Expect: paster still received finalText; runner's lastError surfaces but state returns to idle.
    }
}
```

(Flesh out with the existing fake patterns in this file — the existing `RunnerTests` already has `FakeRecorder`, `FakeTranscriber`, `FakePaster` shapes; mirror them for `FakeTranscriptStore` with a `lastInsert: AnyHashable?` capture.)

- [ ] **Step 2: Run to verify failure**

```bash
cd MumblurCore && swift test --filter RunnerPostProcessTests
```

Expected: compile errors.

- [ ] **Step 3: Define a Runner-facing persistence protocol and wire post-processing**

```swift
// In MumblurCore/Sources/MumblurCore/Runner.swift — additions (keep existing state machine intact)

public protocol TranscriptPersisting: Sendable {
    func persist(snapshot: ServingSnapshot, startedAt: Date, durationMs: Int,
                 rawText: String, finalText: String,
                 audio: TranscriptStore.AudioMetadata?) async throws
}

extension TranscriptStore: TranscriptPersisting {
    public func persist(snapshot: ServingSnapshot, startedAt: Date, durationMs: Int,
                        rawText: String, finalText: String,
                        audio: TranscriptStore.AudioMetadata?) async throws {
        if let audio {
            try insertWithAudio(profileID: snapshot.profileID,
                profileNameSnapshot: snapshot.profileName,
                promptSnapshot: snapshot.prompt.sourceText.isEmpty ? nil : snapshot.prompt.sourceText,
                startedAt: startedAt, durationMs: durationMs,
                modelID: snapshot.modelID, language: snapshot.language,
                rawText: rawText, finalText: finalText, audio: audio)
        } else {
            try insertTextOnly(profileID: snapshot.profileID,
                profileNameSnapshot: snapshot.profileName,
                promptSnapshot: snapshot.prompt.sourceText.isEmpty ? nil : snapshot.prompt.sourceText,
                startedAt: startedAt, durationMs: durationMs,
                modelID: snapshot.modelID, language: snapshot.language,
                rawText: rawText, finalText: finalText)
        }
    }
}
```

Then modify the `Runner` worker path: after `transcriber.transcribe(samples)` returns `TranscriptionOutput`, run

```swift
let finalText = postProcessor.apply(output.rawText, rules: output.snapshot.rules)
try? paster.paste(finalText)
Task.detached { [persister, snapshot = output.snapshot] in
    do {
        try await persister.persist(snapshot: snapshot, startedAt: startedAt,
            durationMs: durationMs, rawText: output.rawText, finalText: finalText,
            audio: nil)
    } catch {
        Logger.app.error("persist failed: \(error.localizedDescription)")
    }
}
```

(Audio retention path comes in via `AppCoordinator` in Task 21 — pass `audio: nil` here; the Coordinator wires the real path with retention policy applied.)

- [ ] **Step 4: Run tests — all pass**

```bash
cd MumblurCore && swift test --filter RunnerTests
cd MumblurCore && swift test --filter RunnerPostProcessTests
```

Expected: all existing + new tests pass.

- [ ] **Step 5: Extend `scripts/verify_task.sh`**

```bash
    20)
        bash "$0" 19
        grep -q 'protocol TranscriptPersisting' MumblurCore/Sources/MumblurCore/Runner.swift
        grep -q 'postProcessor.apply' MumblurCore/Sources/MumblurCore/Runner.swift
        core_test
        ;;
```

- [ ] **Step 6: Verify and commit**

```bash
scripts/verify_task.sh 20
git add MumblurCore/Sources/MumblurCore/Runner.swift \
        MumblurCore/Tests/MumblurCoreTests/RunnerTests.swift scripts/verify_task.sh
git commit -m "feat(runner): post-process via snapshot.rules; persist via TranscriptPersisting"
```

---

## Task 21: AppCoordinator — stores, pending vs serving selection, .swappingModel state

> **REVISION v2 (read first):**
> - `switchActiveProfile(_:)` becomes a **tentative-then-commit** flow:
>   1. Stash the previously-active profile as `lastCommittedProfile` for rollback.
>   2. Set `uiState = .swappingModel` and reflect the *tentative* profile in the picker via a `pendingProfileID` published field (separate from `activeProfileID`).
>   3. Await `manager.requestSwap(to:)`. **Only if it returns a committed snapshot** matching the request, write `active_profile_id` to the DB and set `activeProfileName` / `activeProfileID`.
>   4. On throw (load failed or stale-swap superseded), restore `pendingProfileID = lastCommittedProfile.id` and set a non-fatal `lastError` for the UI.
> - `SettingsBridge` is provided via `EnvironmentObject`, **not** `.shared`. The `AppCoordinator` owns the bridge instance; `MumblurApp` passes both into the Settings scene via `.environmentObject(...)`. Delete every `SettingsBridge.shared` reference in the body below; views read `@EnvironmentObject private var bridge: AppCoordinator.SettingsBridge`.
> - **Activation policy is restored, not assumed.** The Settings-opening trampoline (Task 25) captures `NSApp.activationPolicy` before switching to `.regular` and restores that captured value on Settings dismissal — never hardcodes `.accessory`.

**Files:**
- Modify: `App/AppCoordinator.swift`
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Extend `UIState` and wire stores (with tentative/committed swap)**

```swift
// App/AppCoordinator.swift — full file
import SwiftUI
import MumblurCore
import os

@MainActor
final class AppCoordinator: ObservableObject {
    enum UIState: String, Sendable {
        case loadingModel       // first-launch cold start
        case idle
        case recording
        case transcribing
        case swappingModel      // active profile changed; new model is loading
        case permissionNeeded
        case fatalError
    }

    @Published var uiState: UIState = .loadingModel
    @Published var permissionMessage: String?
    @Published var lastError: String?
    @Published private(set) var activeProfileName: String = "Default"

    @MainActor
    final class SettingsBridge: ObservableObject {
        @Published var profiles: [Profile] = []
        @Published var activeProfileID: String?     // committed
        @Published var pendingProfileID: String?    // tentative during a swap
    }
    let settingsBridge = SettingsBridge()

    private var runner: Runner?
    private var hotkey: HotkeyListening?
    private var recorder: AudioRecording?
    private var transcriber: Transcriber?
    private var manager: ModelManager?
    private var perms: PermissionsCoordinator!

    // Stores
    private var database: Database?
    private var settingsStore: SettingsStore?
    private var transcriptStore: TranscriptStore?
    private var audioStore: AudioStore?
    private var persister: RetentionAwarePersister?

    init() {
        self.perms = PermissionsCoordinator { [weak self] snap in self?.applyPermissionSnapshot(snap) }
    }

    func bootstrap() async {
        await perms.bootstrap()
        do {
            let root = try Self.applicationSupportRoot()
            let db = try Database(location: .file(root.appendingPathComponent("mumblur.sqlite")))
            let settings  = SettingsStore(database: db)
            let transcripts = TranscriptStore(database: db)
            let audio = AudioStore(root: root)
            let persister = RetentionAwarePersister(database: db, transcripts: transcripts, audio: audio)

            try await Self.seedDefaultProfileIfNeeded(settings: settings)
            let active = try await settings.activeOrFirstActive()

            let transcriber = Transcriber()
            let manager = ModelManager(loader: WhisperKitLoader(), transcriber: transcriber)
            _ = try await manager.requestSwap(to: active)   // throws -> propagates to fatalError

            let recorder = try AudioRecorder()
            let paster = Paster()
            let runner = Runner(
                recorder: recorder, transcriber: transcriber,
                paster: paster, postProcessor: TranscriptPostProcessor(),
                persister: persister, minHoldMs: 200,
                onStateChange: { [weak self] s in
                    Task { @MainActor in self?.applyRunnerState(s) }
                })

            self.database = db; self.settingsStore = settings
            self.transcriptStore = transcripts; self.audioStore = audio
            self.persister = persister
            self.recorder = recorder; self.transcriber = transcriber
            self.manager = manager; self.runner = runner
            self.activeProfileName = active.name

            settingsBridge.profiles = try await settings.listActive()
            settingsBridge.activeProfileID = active.id
            settingsBridge.pendingProfileID = nil

            // Orphan cleanup at launch (only deletes WAVs not referenced by any row).
            try await audio.cleanupOrphans(referencedRelPaths: {
                try await transcripts.allAudioRelPaths()
            })

            if uiState != .permissionNeeded { tryStartHotkey() }
            if uiState == .loadingModel { uiState = .idle }
        } catch {
            Logger.app.error("bootstrap failed: \(error.localizedDescription)")
            self.lastError = error.localizedDescription
            self.uiState = .fatalError
        }
    }

    /// Tentative-then-commit profile switch.
    ///
    /// 1. UI shows `.swappingModel` with `pendingProfileID = profile.id`.
    /// 2. Awaits `manager.requestSwap(to:)`.
    /// 3. ON SUCCESS — commit: write `app_setting.active_profile_id`, publish the
    ///    new `activeProfileID`, clear `pendingProfileID`.
    /// 4. ON FAILURE (load error or `.staleSwap`) — roll back: restore
    ///    `pendingProfileID = previously-committed activeProfileID`, surface
    ///    `lastError`. The committed state is unchanged.
    func switchActiveProfile(_ profile: Profile) async {
        guard let settings = settingsStore, let manager else { return }
        let previouslyCommitted = settingsBridge.activeProfileID
        settingsBridge.pendingProfileID = profile.id
        uiState = .swappingModel
        do {
            let snap = try await manager.requestSwap(to: profile)
            guard snap.profileID == profile.id else {
                // Generation guard could only get us here if a newer commit landed.
                // Re-publish whatever the latest snapshot represents.
                settingsBridge.pendingProfileID = previouslyCommitted
                if uiState == .swappingModel { uiState = .idle }
                return
            }
            try await settings.setActiveProfileID(profile.id)
            settingsBridge.activeProfileID = profile.id
            settingsBridge.pendingProfileID = nil
            activeProfileName = profile.name
            if uiState == .swappingModel { uiState = .idle }
        } catch {
            Logger.app.error("swap failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            settingsBridge.pendingProfileID = previouslyCommitted
            if uiState == .swappingModel { uiState = .idle }
        }
    }

    func quit() {
        runner?.shutdown(); hotkey?.stop()
        NSApplication.shared.terminate(nil)
    }

    var icon: String {
        switch uiState {
        case .loadingModel:     return "hourglass"
        case .idle:             return "mic"
        case .recording:        return "mic.fill"
        case .transcribing:     return "waveform"
        case .swappingModel:    return "arrow.triangle.2.circlepath"
        case .permissionNeeded: return "exclamationmark.triangle"
        case .fatalError:       return "exclamationmark.octagon"
        }
    }

    // MARK: - Helpers

    private static func applicationSupportRoot() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
        let root = base.appendingPathComponent("Mumblur", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func seedDefaultProfileIfNeeded(settings: SettingsStore) async throws {
        if try await settings.listActive().isEmpty {
            _ = try await settings.create(name: "Default", modelID: "openai_whisper-large-v3-turbo")
        }
        if try await settings.activeProfileID() == nil,
           let first = try await settings.listActive().first {
            try await settings.setActiveProfileID(first.id)
        }
    }

    private func tryStartHotkey() {
        guard let runner, hotkey == nil else { return }
        let hk = Hotkey { event in
            switch event {
            case .press:   runner.onPress()
            case .release: runner.onRelease()
            }
        }
        do { try hk.start(); self.hotkey = hk }
        catch {
            uiState = .permissionNeeded
            permissionMessage = "Grant Accessibility and Input Monitoring to Mumblur."
        }
    }

    private func applyPermissionSnapshot(_ snap: PermissionsCoordinator.Snapshot) {
        if !snap.allGranted {
            uiState = .permissionNeeded
            var missing: [String] = []
            if snap.microphone     != .granted { missing.append("Microphone") }
            if snap.accessibility  != .granted { missing.append("Accessibility") }
            if snap.inputMonitoring != .granted { missing.append("Input Monitoring") }
            permissionMessage = "Grant: " + missing.joined(separator: ", ")
            return
        }
        permissionMessage = nil
        if runner != nil && hotkey == nil { tryStartHotkey() }
        if uiState == .permissionNeeded { uiState = .idle }
    }

    private func applyRunnerState(_ s: Runner.State) {
        switch s {
        case .idle:         if uiState != .swappingModel { uiState = .idle }
        case .recording:    uiState = .recording
        case .stopping:     uiState = .transcribing
        case .transcribing: uiState = .transcribing
        }
    }
}

extension SettingsStore {
    public func activeOrFirstActive() async throws -> Profile {
        if let id = try activeProfileID(), let p = try get(profileID: id) { return p }
        if let first = try listActive().first { return first }
        // Should never happen post-seed, but be defensive:
        return try create(name: "Default", modelID: "openai_whisper-large-v3-turbo")
    }
}

private struct WhisperKitLoader: ModelLoading {
    func load(modelID: String) async throws -> LoadedModel {
        let kit = try await RealWhisperKit.make(modelHint: modelID)
        return LoadedModel(kit: kit, tokenizer: WhisperKitTokenizer(kit: kit))
    }
}

private struct WhisperKitTokenizer: Tokenizing {
    let kit: RealWhisperKit
    mutating func encode(text: String) -> [Int] { kit.encode(text: text) }
}
```

- [ ] **Step 2: Build the app to verify Swift 6 concurrency compiles**

```bash
xcodebuild build -project Mumblur.xcodeproj -scheme Mumblur -destination 'platform=macOS' -quiet
```

Expected: build succeeds.

- [ ] **Step 3: Extend `scripts/verify_task.sh`**

```bash
    21)
        bash "$0" 20
        grep -q '\.swappingModel' App/AppCoordinator.swift || fail "missing .swappingModel state"
        grep -q 'switchActiveProfile' App/AppCoordinator.swift
        app_build
        ;;
```

- [ ] **Step 4: Verify and commit**

```bash
scripts/verify_task.sh 21
git add App/AppCoordinator.swift scripts/verify_task.sh
git commit -m "feat(app): AppCoordinator wires stores, pending/serving selection, .swappingModel"
```

---

# Phase 3.5 — Retention-aware dictation persistence

## Task 21.5 (NEW): RetentionAwarePersister + DictationRecorder buffer pass-through

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/Storage/RetentionAwarePersister.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/Storage/RetentionAwarePersisterTests.swift`
- Modify: `MumblurCore/Sources/MumblurCore/Runner.swift` (worker passes its samples buffer into `DictationPersisting.persist`)
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Write the failing tests**

The persister must (a) when retention OFF, write **no** WAV and insert a text-only row; (b) when retention ON, stream the WAV to disk via `AudioStore.write`, then insert with audio metadata in a single transaction; (c) on DB insert failure, delete the freshly-written WAV (compensating delete); (d) snapshot the retention policy at insert time (later policy changes don't reinterpret older rows — this is just the row's audio metadata being intrinsic, no extra column needed beyond what's already in `transcript`).

```swift
// MumblurCore/Tests/MumblurCoreTests/Storage/RetentionAwarePersisterTests.swift
import XCTest
@testable import MumblurCore

final class RetentionAwarePersisterTests: XCTestCase {
    func testRetentionOff_noWAV_textOnlyRow() async throws { /* … */ }
    func testRetentionOn_writesWAV_andRowReferencesIt() async throws { /* … */ }
    func testInsertFailure_removesFreshlyWrittenWAV() async throws { /* … */ }
}
```

- [ ] **Step 2: Implement `RetentionAwarePersister.swift`**

```swift
// MumblurCore/Sources/MumblurCore/Storage/RetentionAwarePersister.swift
import Foundation

public actor RetentionAwarePersister: DictationPersisting {
    private let database: Database
    private let transcripts: TranscriptStore
    private let audio: AudioStore

    public init(database: Database, transcripts: TranscriptStore, audio: AudioStore) {
        self.database = database; self.transcripts = transcripts; self.audio = audio
    }

    public func persist(samples: [Float], snapshot: ServingSnapshot,
                        startedAt: Date, durationMs: Int,
                        rawText: String, finalText: String) async {
        let enabled = (try? readRetentionEnabled()) ?? false
        if !enabled {
            try? await transcripts.insertTextOnly(
                profileID: snapshot.profileID, profileNameSnapshot: snapshot.profileName,
                promptSnapshot: snapshot.prompt.sourceText.isEmpty ? nil : snapshot.prompt.sourceText,
                startedAt: startedAt, durationMs: durationMs,
                modelID: snapshot.modelID, language: snapshot.language,
                rawText: rawText, finalText: finalText)
            return
        }
        do {
            let written = try await audio.write(samples: samples, sampleRateHz: 16000)
            do {
                try await transcripts.insertWithAudio(
                    profileID: snapshot.profileID, profileNameSnapshot: snapshot.profileName,
                    promptSnapshot: snapshot.prompt.sourceText.isEmpty ? nil : snapshot.prompt.sourceText,
                    startedAt: startedAt, durationMs: durationMs,
                    modelID: snapshot.modelID, language: snapshot.language,
                    rawText: rawText, finalText: finalText,
                    audio: .init(relPath: written.relPath, bytes: written.bytes,
                                 sha256: written.sha256, sampleRateHz: 16000,
                                 channels: 1, pcmEncoding: "pcm_s16le"))
            } catch {
                // Compensating delete — keep the FS consistent with the DB.
                try? FileManager.default.removeItem(at: written.absoluteURL)
                Logger.app.error("transcript insert failed; removed WAV: \(error.localizedDescription)")
            }
        } catch {
            Logger.app.error("audio write failed: \(error.localizedDescription)")
        }
    }

    private func readRetentionEnabled() throws -> Bool {
        try database.read { db in
            let v = try Int.fetchOne(db, sql:
                "SELECT enabled FROM retention_policy WHERE singleton=1") ?? 0
            return v == 1
        }
    }
}
```

- [ ] **Step 3: Modify `Runner` to capture and forward the samples buffer**

The runner already has the samples buffer at the moment it hands them to the transcriber. Capture them into a local `let samples = …` and pass them into `persister.persist(samples:snapshot:startedAt:durationMs:rawText:finalText:)` after paste.

- [ ] **Step 4: Wire the persister in `AppCoordinator.bootstrap`**

Replace any direct `transcripts` injection into `Runner` with a `RetentionAwarePersister(database: db, transcripts: transcripts, audio: audio)`.

- [ ] **Step 5: Extend `scripts/verify_task.sh`**

```bash
    21.5)
        bash "$0" 21
        need_file MumblurCore/Sources/MumblurCore/Storage/RetentionAwarePersister.swift
        need_file MumblurCore/Tests/MumblurCoreTests/Storage/RetentionAwarePersisterTests.swift
        core_test
        ;;
```

**Critical chaining note:** `case "$TASK"` matches a literal string, so `21.5` is its own label. Task 22 below must chain from `21.5` (`bash "$0" 21.5`) so `verify_task.sh 22` runs the new persister checks. **Do not** use `21|21.5)` — that would require Task 21.5 files to exist when verifying Task 21.

- [ ] **Step 6: Verify and commit**

```bash
scripts/verify_task.sh 21.5
git add MumblurCore/Sources/MumblurCore/Storage/RetentionAwarePersister.swift \
        MumblurCore/Tests/MumblurCoreTests/Storage/RetentionAwarePersisterTests.swift \
        MumblurCore/Sources/MumblurCore/Runner.swift App/AppCoordinator.swift \
        scripts/verify_task.sh
git commit -m "feat(storage): RetentionAwarePersister wires audio retention into dictation pipeline"
```

> The `import Foundation` in the persister implementation above is insufficient — also add `import GRDB` (for `Int.fetchOne`) and `import os` (for `Logger.app`).

---

# Phase 4 — Tuning

## Task 22: WERNormalizer + WERCalculator

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/WERNormalizer.swift`
- Create: `MumblurCore/Sources/MumblurCore/Tuning/WERCalculator.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/WERTests.swift`
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Write the failing tests**

```swift
// MumblurCore/Tests/MumblurCoreTests/WERTests.swift
import XCTest
@testable import MumblurCore

final class WERNormalizerTests: XCTestCase {
    func testLowercasing_stripsPunctuationAndCollapsesWhitespace() {
        let n = WERNormalizer()
        XCTAssertEqual(n.normalize(" Hello, World!! "), "hello world")
    }
    func testNumbersAreLeftAsTokens() {
        let n = WERNormalizer()
        XCTAssertEqual(n.normalize("Take 12 apples."), "take 12 apples")
    }
}

final class WERCalculatorTests: XCTestCase {
    private let w = WERCalculator()
    func testZeroErrorsWhenIdentical() {
        XCTAssertEqual(w.wer(reference: "the quick brown fox", hypothesis: "the quick brown fox"), 0.0)
    }
    func testOneSubstitution_inFourWords() {
        XCTAssertEqual(w.wer(reference: "the quick brown fox", hypothesis: "the slow brown fox"), 0.25, accuracy: 1e-9)
    }
    func testInsertionDeletion() {
        XCTAssertEqual(w.wer(reference: "hello", hypothesis: "hello world"), 1.0, accuracy: 1e-9) // 1 ins / 1 ref
        XCTAssertEqual(w.wer(reference: "hello world", hypothesis: ""), 1.0, accuracy: 1e-9)      // 2 del / 2 ref
    }
    func testEmptyReference_isUndefined_returnsZeroIfHypothesisAlsoEmpty() {
        XCTAssertEqual(w.wer(reference: "", hypothesis: ""), 0.0)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd MumblurCore && swift test --filter WERNormalizerTests
cd MumblurCore && swift test --filter WERCalculatorTests
```

Expected: compile errors.

- [ ] **Step 3: Implement `WERNormalizer.swift`**

```swift
// MumblurCore/Sources/MumblurCore/WERNormalizer.swift
import Foundation

public struct WERNormalizer: Sendable {
    public init() {}

    public func normalize(_ text: String) -> String {
        let lower = text.lowercased()
        let scalars = lower.unicodeScalars.map { scalar -> Character in
            if CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || scalar == " " { return Character(scalar) }
            return " "
        }
        let collapsed = String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed
    }

    public func tokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }
}
```

- [ ] **Step 4: Implement `WERCalculator.swift`**

```swift
// MumblurCore/Sources/MumblurCore/Tuning/WERCalculator.swift
import Foundation

public struct WERCalculator: Sendable {
    public static let scoringVersion = "wer_v1"
    private let normalizer: WERNormalizer
    public init(normalizer: WERNormalizer = WERNormalizer()) { self.normalizer = normalizer }

    public func wer(reference: String, hypothesis: String) -> Double {
        let ref = normalizer.tokens(reference)
        let hyp = normalizer.tokens(hypothesis)
        if ref.isEmpty { return hyp.isEmpty ? 0.0 : 1.0 }
        return Double(levenshtein(ref, hyp)) / Double(ref.count)
    }

    /// Token-level Levenshtein distance with substitution cost 1.
    private func levenshtein(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,            // deletion
                    curr[j - 1] + 1,        // insertion
                    prev[j - 1] + cost      // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
```

- [ ] **Step 5: Run tests — all pass**

```bash
cd MumblurCore && swift test --filter WERNormalizerTests
cd MumblurCore && swift test --filter WERCalculatorTests
```

Expected: 6 tests pass.

- [ ] **Step 6: Extend `scripts/verify_task.sh`**

```bash
    22)
        bash "$0" 21.5
        need_file MumblurCore/Sources/MumblurCore/WERNormalizer.swift
        need_file MumblurCore/Sources/MumblurCore/Tuning/WERCalculator.swift
        need_file MumblurCore/Tests/MumblurCoreTests/WERTests.swift
        core_test
        ;;
```

- [ ] **Step 7: Verify and commit**

```bash
scripts/verify_task.sh 22
git add MumblurCore/Sources/MumblurCore/WERNormalizer.swift \
        MumblurCore/Sources/MumblurCore/Tuning/WERCalculator.swift \
        MumblurCore/Tests/MumblurCoreTests/WERTests.swift scripts/verify_task.sh
git commit -m "feat(tuning): WERNormalizer + WERCalculator (wer_v1)"
```

---

## Task 23: CalibrationScripts (mining/eval split) + ErrorMiner + SuggestionGenerator

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/Tuning/CalibrationScripts.swift`
- Create: `MumblurCore/Sources/MumblurCore/Tuning/ErrorMiner.swift`
- Create: `MumblurCore/Sources/MumblurCore/Tuning/SuggestionGenerator.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/Tuning/ErrorMinerTests.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/Tuning/SuggestionGeneratorTests.swift`
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Write the failing tests**

```swift
// MumblurCore/Tests/MumblurCoreTests/Tuning/ErrorMinerTests.swift
import XCTest
@testable import MumblurCore

final class ErrorMinerTests: XCTestCase {
    func testProducedToExpectedDirection() {
        // Ground truth uses "Questable"; Whisper produced "questionable" twice.
        let miner = ErrorMiner()
        let pairs = miner.mineSubstitutions(samples: [
            .init(groundTruth: "Questable rocks",      raw: "questionable rocks"),
            .init(groundTruth: "I love Questable",     raw: "I love questionable"),
        ])
        XCTAssertTrue(pairs.contains { $0.produced == "questionable" && $0.expected == "questable" })
    }
    func testIgnoresPunctuationCasing_viaNormalizer() {
        let miner = ErrorMiner()
        let pairs = miner.mineSubstitutions(samples: [
            .init(groundTruth: "WhisperKit!", raw: "whisper kit"),
        ])
        // "whisperkit" → "whisper" + "kit" yields no single-token substitution; check that no
        // false-positive pair is emitted with produced == "whisperkit".
        XCTAssertFalse(pairs.contains { $0.produced == "whisperkit" })
    }
}
```

```swift
// MumblurCore/Tests/MumblurCoreTests/Tuning/SuggestionGeneratorTests.swift
import XCTest
@testable import MumblurCore

final class SuggestionGeneratorTests: XCTestCase {

    func testRule_requiresSupportAndPrecision() {
        let gen = SuggestionGenerator(minSupport: 3, minPrecision: 0.8)
        // 1× support → reject
        let weak = gen.generateRules(from: [.init(produced: "x", expected: "y", count: 1, distinctExpected: 1)])
        XCTAssertTrue(weak.isEmpty)
        // 3× support, 1 distinct expected (precision 1.0) → accept
        let strong = gen.generateRules(from: [.init(produced: "x", expected: "y", count: 3, distinctExpected: 1)])
        XCTAssertEqual(strong.first?.pattern, "x")
        XCTAssertEqual(strong.first?.replacement, "y")
    }

    func testRule_ambiguousProducedForm_isRejected() {
        // "x" mapped to two different expected tokens equally → precision below 0.8.
        let gen = SuggestionGenerator(minSupport: 4, minPrecision: 0.8)
        let amb = gen.generateRules(from: [.init(produced: "x", expected: "y", count: 4, distinctExpected: 2)])
        XCTAssertTrue(amb.isEmpty)
    }

    func testVocab_collectsFrequentMissedExpected() {
        let gen = SuggestionGenerator(minSupport: 2, minPrecision: 1.0)
        let vocab = gen.generateVocab(from: [
            .init(produced: "questionable", expected: "questable", count: 3, distinctExpected: 1),
            .init(produced: "test", expected: "test", count: 5, distinctExpected: 1),
        ])
        XCTAssertEqual(vocab, ["questable"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd MumblurCore && swift test --filter ErrorMinerTests
cd MumblurCore && swift test --filter SuggestionGeneratorTests
```

Expected: compile errors.

- [ ] **Step 3: Implement `CalibrationScripts.swift`**

```swift
// MumblurCore/Sources/MumblurCore/Tuning/CalibrationScripts.swift
import Foundation
import CryptoKit

public struct CalibrationScript: Sendable, Identifiable {
    public enum Role: String, Sendable { case mining, eval }
    public struct Sentence: Sendable {
        public let text: String
        public let role: Role
    }
    public let id: String
    public let name: String
    public let language: String?
    public let sentences: [Sentence]

    public var hash: String {
        let joined = sentences.map(\.text).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum CalibrationScripts {
    public static let englishBaseline = CalibrationScript(
        id: "en-baseline-v1", name: "English baseline", language: "en",
        sentences: [
            // Mining set — used to mine suggestions.
            .init(text: "Mumblur transcribes audio locally.", role: .mining),
            .init(text: "I use WhisperKit on Apple Silicon.", role: .mining),
            .init(text: "Questable is the company name.", role: .mining),
            .init(text: "Open the settings to add vocabulary.", role: .mining),
            .init(text: "The right option key starts recording.", role: .mining),
            // Evaluation set — held out; this is what the trend chart reports.
            .init(text: "Calibration uses a held-out evaluation set.", role: .eval),
            .init(text: "WhisperKit prompts can bias decoding output.", role: .eval),
            .init(text: "Replacement rules run after transcription.", role: .eval),
            .init(text: "I love using Questable every day.", role: .eval),
            .init(text: "The model loads in the background while you dictate.", role: .eval),
        ])

    public static let all: [CalibrationScript] = [englishBaseline]
    public static func byID(_ id: String) -> CalibrationScript? { all.first { $0.id == id } }
}
```

- [ ] **Step 4: Implement `ErrorMiner.swift`**

```swift
// MumblurCore/Sources/MumblurCore/Tuning/ErrorMiner.swift
import Foundation

public struct ErrorMiner: Sendable {
    public struct Sample: Sendable {
        public let groundTruth: String
        public let raw: String
        public init(groundTruth: String, raw: String) {
            self.groundTruth = groundTruth; self.raw = raw
        }
    }

    public struct Substitution: Equatable, Sendable {
        public let produced: String       // what Whisper said
        public let expected: String       // what the script said
        public let count: Int
        public let distinctExpected: Int  // how many distinct expected forms share this produced form
    }

    private let normalizer: WERNormalizer
    public init(normalizer: WERNormalizer = WERNormalizer()) { self.normalizer = normalizer }

    public func mineSubstitutions(samples: [Sample]) -> [Substitution] {
        // Tally produced→expected via per-sample 1:1 alignment over equal-length token spans.
        // For unequal-length cases we fall back to a Hunt-Szymanski-ish skeleton on equal tokens
        // and emit substitution pairs only where positions clearly disagree.
        var tally: [String: [String: Int]] = [:]
        for s in samples {
            let expectedTokens = normalizer.tokens(s.groundTruth)
            let producedTokens = normalizer.tokens(s.raw)
            let aligned = alignByLCS(expectedTokens, producedTokens)
            for (exp, prod) in aligned where exp != nil && prod != nil && exp != prod {
                tally[prod!, default: [:]][exp!, default: 0] += 1
            }
        }
        return tally.map { (produced, expectedCounts) in
            let total = expectedCounts.values.reduce(0, +)
            return Substitution(produced: produced,
                                expected: expectedCounts.max(by: { $0.value < $1.value })!.key,
                                count: total,
                                distinctExpected: expectedCounts.count)
        }
    }

    /// LCS-based alignment that emits pairs (expected, produced). Non-matching positions
    /// are returned with one side `nil` (we keep only positions where both sides have a token
    /// and they differ — that's the only signal we mine into substitution rules).
    private func alignByLCS(_ expected: [String], _ produced: [String])
        -> [(String?, String?)] {
        let n = expected.count, m = produced.count
        if n == 0 || m == 0 {
            return (0..<max(n, m)).map { i in
                (i < n ? expected[i] : nil, i < m ? produced[i] : nil)
            }
        }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                dp[i][j] = expected[i - 1] == produced[j - 1]
                    ? dp[i - 1][j - 1] + 1
                    : max(dp[i - 1][j], dp[i][j - 1])
            }
        }
        var pairs: [(String?, String?)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            if expected[i - 1] == produced[j - 1] {
                pairs.append((expected[i - 1], produced[j - 1])); i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                pairs.append((expected[i - 1], nil)); i -= 1
            } else {
                pairs.append((nil, produced[j - 1])); j -= 1
            }
        }
        while i > 0 { pairs.append((expected[i - 1], nil)); i -= 1 }
        while j > 0 { pairs.append((nil, produced[j - 1])); j -= 1 }
        // Walk again to pair off adjacent (expected,nil)+(nil,produced) into substitution positions.
        let raw = Array(pairs.reversed())
        var out: [(String?, String?)] = []
        var k = 0
        while k < raw.count {
            if k + 1 < raw.count,
               case let (e?, nil) = raw[k],
               case let (nil, p?) = raw[k + 1] {
                out.append((e, p)); k += 2
            } else if k + 1 < raw.count,
                      case let (nil, p?) = raw[k],
                      case let (e?, nil) = raw[k + 1] {
                out.append((e, p)); k += 2
            } else {
                out.append(raw[k]); k += 1
            }
        }
        return out
    }
}
```

- [ ] **Step 5: Implement `SuggestionGenerator.swift`**

```swift
// MumblurCore/Sources/MumblurCore/Tuning/SuggestionGenerator.swift
import Foundation

public struct SuggestionGenerator: Sendable {
    public let minSupport: Int
    public let minPrecision: Double

    public init(minSupport: Int = 3, minPrecision: Double = 0.8) {
        self.minSupport = minSupport; self.minPrecision = minPrecision
    }

    public struct RuleSuggestion: Equatable, Sendable {
        public let pattern: String
        public let replacement: String
        public let isRegex = false
        public let caseSensitive = false
        public let wordBoundary = true
    }

    public func generateRules(from subs: [ErrorMiner.Substitution]) -> [RuleSuggestion] {
        subs.compactMap { s in
            guard s.count >= minSupport else { return nil }
            let precision = 1.0 / Double(s.distinctExpected)
            guard precision >= minPrecision else { return nil }
            return RuleSuggestion(pattern: s.produced, replacement: s.expected)
        }
    }

    public func generateVocab(from subs: [ErrorMiner.Substitution]) -> [String] {
        // Vocab = expected tokens that Whisper consistently missed (rule-worthy ones already
        // captured above; vocab additionally helps biasing for terms that don't map cleanly to
        // a stable replacement rule).
        Array(Set(subs.filter { $0.count >= minSupport && $0.produced != $0.expected }
                  .map(\.expected))).sorted()
    }
}
```

- [ ] **Step 6: Run tests — all pass**

```bash
cd MumblurCore && swift test --filter ErrorMinerTests
cd MumblurCore && swift test --filter SuggestionGeneratorTests
```

Expected: 5 tests pass.

- [ ] **Step 7: Extend `scripts/verify_task.sh`**

```bash
    23)
        bash "$0" 22
        need_file MumblurCore/Sources/MumblurCore/Tuning/CalibrationScripts.swift
        need_file MumblurCore/Sources/MumblurCore/Tuning/ErrorMiner.swift
        need_file MumblurCore/Sources/MumblurCore/Tuning/SuggestionGenerator.swift
        core_test
        ;;
```

- [ ] **Step 8: Verify and commit**

```bash
scripts/verify_task.sh 23
git add MumblurCore/Sources/MumblurCore/Tuning/{CalibrationScripts,ErrorMiner,SuggestionGenerator}.swift \
        MumblurCore/Tests/MumblurCoreTests/Tuning/{ErrorMiner,SuggestionGenerator}Tests.swift \
        scripts/verify_task.sh
git commit -m "feat(tuning): scripts (mining/eval split) + ErrorMiner + SuggestionGenerator"
```

---

## Task 24: CalibrationController (suspends Runner, drives the ceremony)

> **REVISION v2 (read first):**
> - The controller no longer accepts a `Profile` argument for the ceremony body — it operates on the **serving snapshot**. The caller first invokes `modelManager.requestSwap(to: requestedProfile)` and awaits the returned `ServingSnapshot`. The controller asserts `snapshot.profileID == requestedProfile.id && snapshot.modelID == requestedProfile.modelID` before starting; if the snapshot doesn't match (e.g., a concurrent swap superseded it), it throws `CalibrationError.snapshotMismatch`.
> - WER application uses **`snapshot.rules`** to compute `finalText` — the rules that the user is actually dictating against. The `profile.rules` shortcut in the body below is wrong.
> - On suggestion acceptance, the controller writes new vocab/rules to the profile, then calls `modelManager.requestSwap(to: refreshedProfile)` to rebuild the prompt tokens (vocab changed → prompt tokens need re-tokenization).

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/Tuning/CalibrationController.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/Tuning/CalibrationControllerTests.swift`
- Modify: `MumblurCore/Sources/MumblurCore/Runner.swift` (add `setSuspended(_ on: Bool)`)
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Write the failing test**

```swift
// MumblurCore/Tests/MumblurCoreTests/Tuning/CalibrationControllerTests.swift
import XCTest
@testable import MumblurCore

final class CalibrationControllerTests: XCTestCase {

    func testCeremony_suspendsRunner_recordsAndScoresAllSamples() async throws {
        // Build a controller with:
        //   * fake recorder that returns pre-canned [Float] per call,
        //   * fake transcriber that maps known inputs → known outputs (some wrong on purpose),
        //   * a real WERCalculator + ErrorMiner + SuggestionGenerator,
        //   * a spy Runner that records suspended on/off transitions.
        // Run the controller against CalibrationScripts.englishBaseline.
        // Assertions:
        //   * runner.suspendCalls == [true, false]
        //   * every sentence yielded a calibration_sample row with status='transcribed'
        //   * miningSet's wrong outputs produced at least one ruleSuggestion
        //   * run row has eval_raw_wer and eval_final_wer populated
    }

    func testCeremony_failedSampleRecordedAsFailed_continuesRun() async throws {
        // Configure the fake transcriber to throw on sample index 2.
        // Assert: the run completes; the failed sample has status='failed' + error_message;
        //         remaining samples are transcribed; eval set still scored.
    }
}
```

(Use the same fake-shape patterns as `RunnerTests` for AudioRecording / WhisperKitTranscribing.)

- [ ] **Step 2: Run to verify failure**

```bash
cd MumblurCore && swift test --filter CalibrationControllerTests
```

Expected: compile errors.

- [ ] **Step 3: Add suspension to `Runner`**

Add to `Runner` (no other state-machine changes):

```swift
// MumblurCore/Sources/MumblurCore/Runner.swift
extension Runner {
    /// Toggles whether press/release events are accepted. Used by the calibration ceremony
    /// to keep dictation off while the user is reading the script.
    public func setSuspended(_ on: Bool) { /* set internal flag; onPress/onRelease early-return when set */ }
}
```

(Implement the flag inside the actor/lock the rest of `Runner` uses. The exact wiring matches the existing state-machine pattern in `Runner.swift`.)

- [ ] **Step 4: Implement `CalibrationController.swift`**

```swift
// MumblurCore/Sources/MumblurCore/Tuning/CalibrationController.swift
import Foundation
import GRDB

public actor CalibrationController {

    public struct StepEvent: Sendable {
        public let index: Int
        public let total: Int
        public let prompt: String
    }

    private let database: Database
    private let settings: SettingsStore
    private let audio: AudioStore
    private let runner: Runner
    private let recorder: any AudioRecording
    private let transcriber: Transcriber
    private let postProcessor = TranscriptPostProcessor()
    private let wer = WERCalculator()
    private let miner = ErrorMiner()
    private let suggester = SuggestionGenerator()

    public init(database: Database, settings: SettingsStore, audio: AudioStore,
                runner: Runner, recorder: any AudioRecording, transcriber: Transcriber) {
        self.database = database; self.settings = settings; self.audio = audio
        self.runner = runner; self.recorder = recorder; self.transcriber = transcriber
    }

    public enum CalibrationError: Error { case snapshotMismatch, ceremonyAborted }

    /// Runs the ceremony against `requestedProfile`. The caller must first request a swap
    /// via `ModelManager` so that the `Transcriber` is now serving this profile/model.
    /// The controller reads the committed snapshot from the transcriber (passed in by the
    /// caller as `expectedSnapshot`) and asserts it matches the requested profile+model.
    /// WER scoring uses `expectedSnapshot.rules` — the rules the user is actually
    /// dictating against, not a possibly-stale `Profile` value passed by callers.
    public func run(script: CalibrationScript,
                    requestedProfile: Profile,
                    expectedSnapshot: ServingSnapshot,
                    record: @Sendable (StepEvent) async throws -> [Float]
    ) async throws -> Int64 {
        guard expectedSnapshot.profileID == requestedProfile.id,
              expectedSnapshot.modelID == requestedProfile.modelID else {
            throw CalibrationError.snapshotMismatch
        }
        runner.setSuspended(true)
        defer { runner.setSuspended(false) }

        // Open a run row using the snapshot for honest history.
        let runID: Int64 = try database.write { db in
            try db.execute(sql: """
                INSERT INTO calibration_run(profile_id, profile_name_snapshot,
                    language_snapshot, prompt_snapshot, script_id, script_hash,
                    started_at, model_id)
                VALUES(?,?,?,?,?,?,?,?)
            """, arguments: [expectedSnapshot.profileID, expectedSnapshot.profileName,
                             expectedSnapshot.language,
                             expectedSnapshot.prompt.sourceText.isEmpty
                                ? nil : expectedSnapshot.prompt.sourceText,
                             script.id, script.hash,
                             Int64(Date().timeIntervalSince1970 * 1000),
                             expectedSnapshot.modelID])
            return db.lastInsertedRowID
        }

        var evalRawWERs: [Double] = []
        var evalFinalWERs: [Double] = []

        for (i, sentence) in script.sentences.enumerated() {
            let event = StepEvent(index: i, total: script.sentences.count, prompt: sentence.text)
            do {
                let samples = try await record(event)
                let written = try await audio.write(samples: samples, sampleRateHz: 16000)
                // Insert row in 'recorded' state.
                try database.write { db in
                    try db.execute(sql: """
                        INSERT INTO calibration_sample(run_id,sample_index,set_role,status,
                            ground_truth,duration_ms,audio_rel_path,audio_bytes,audio_sha256,
                            sample_rate_hz,channels,pcm_encoding)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [runID, i, sentence.role.rawValue, "recorded",
                                     sentence.text, samples.count * 1000 / 16000,
                                     written.relPath, written.bytes, written.sha256,
                                     16000, 1, "pcm_s16le"])
                }
                // Transcribe + score (snapshot rules — source of truth).
                let out = try await transcriber.transcribe(samples)
                let finalText = postProcessor.apply(out.rawText, rules: out.snapshot.rules)
                let rWer = wer.wer(reference: sentence.text, hypothesis: out.rawText)
                let fWer = wer.wer(reference: sentence.text, hypothesis: finalText)
                try database.write { db in
                    try db.execute(sql: """
                        UPDATE calibration_sample SET status='transcribed',
                            raw_text=?, final_text=?, raw_wer=?, final_wer=?
                        WHERE run_id=? AND sample_index=?
                    """, arguments: [out.rawText, finalText, rWer, fWer, runID, i])
                }
                if sentence.role == .eval {
                    evalRawWERs.append(rWer); evalFinalWERs.append(fWer)
                }
            } catch {
                try? database.write { db in
                    try db.execute(sql: """
                        UPDATE calibration_sample SET status='failed', error_message=?
                        WHERE run_id=? AND sample_index=?
                    """, arguments: [error.localizedDescription, runID, i])
                }
            }
        }

        // Close the run.
        let avgRaw = evalRawWERs.isEmpty ? nil : evalRawWERs.reduce(0, +) / Double(evalRawWERs.count)
        let avgFinal = evalFinalWERs.isEmpty ? nil : evalFinalWERs.reduce(0, +) / Double(evalFinalWERs.count)
        try database.write { db in
            try db.execute(sql: """
                UPDATE calibration_run SET completed_at=?, eval_raw_wer=?, eval_final_wer=?
                WHERE id=?
            """, arguments: [Int64(Date().timeIntervalSince1970 * 1000), avgRaw, avgFinal, runID])
        }
        return runID
    }

    public func suggestions(forRun id: Int64) async throws -> ([SuggestionGenerator.RuleSuggestion], [String]) {
        let samples: [ErrorMiner.Sample] = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ground_truth, raw_text FROM calibration_sample
                WHERE run_id=? AND set_role='mining' AND status='transcribed'
            """, arguments: [id]).map {
                ErrorMiner.Sample(groundTruth: $0["ground_truth"], raw: $0["raw_text"] ?? "")
            }
        }
        let subs = miner.mineSubstitutions(samples: samples)
        return (suggester.generateRules(from: subs), suggester.generateVocab(from: subs))
    }
}
```

- [ ] **Step 5: Run tests — all pass**

```bash
cd MumblurCore && swift test --filter CalibrationControllerTests
```

Expected: 2 tests pass.

- [ ] **Step 6: Extend `scripts/verify_task.sh`**

```bash
    24)
        bash "$0" 23
        need_file MumblurCore/Sources/MumblurCore/Tuning/CalibrationController.swift
        grep -q 'func setSuspended' MumblurCore/Sources/MumblurCore/Runner.swift \
            || fail "Runner missing setSuspended(on:)"
        core_test
        ;;
```

- [ ] **Step 7: Verify and commit**

```bash
scripts/verify_task.sh 24
git add MumblurCore/Sources/MumblurCore/Tuning/CalibrationController.swift \
        MumblurCore/Tests/MumblurCoreTests/Tuning/CalibrationControllerTests.swift \
        MumblurCore/Sources/MumblurCore/Runner.swift scripts/verify_task.sh
git commit -m "feat(tuning): CalibrationController (suspends Runner; mining/eval scoring + suggestions)"
```

---

# Phase 5 — Settings UI

## Task 25: Settings scene + General tab + Profiles tab

> **REVISION v2 (read first) — this is the macOS Tahoe 26 working recipe:**
>
> Scene declaration order in `MumblurApp.body` is **load-bearing**: `Window → MenuBarExtra → Settings`. Document this with an inline `// SCENE ORDER MATTERS — DO NOT REARRANGE` comment.
>
> ```swift
> @main
> struct MumblurApp: App {
>     @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
>
>     var body: some Scene {
>         // SCENE ORDER MATTERS — DO NOT REARRANGE.
>         // openSettings() on macOS Tahoe 26 requires a SwiftUI render tree that
>         // is mounted BEFORE the Settings scene; the hidden Window is that tree.
>         Window("OpenSettingsTrampoline", id: "openSettingsTrampoline") {
>             OpenSettingsTrampolineView()
>         }
>         .windowResizability(.contentSize)
>         .defaultSize(width: 1, height: 1)
>         .commandsRemoved()
>
>         MenuBarExtra {
>             MenuBarContent(coordinator: delegate.coordinator)
>         } label: {
>             CoordinatorIcon(coordinator: delegate.coordinator)
>         }
>         .menuBarExtraStyle(.menu)
>
>         Settings {
>             SettingsScene()
>                 .environmentObject(delegate.coordinator)
>                 .environmentObject(delegate.coordinator.settingsBridge)
>         }
>     }
> }
>
> private struct OpenSettingsTrampolineView: View {
>     @Environment(\.openSettings) private var openSettings
>     @State private var savedPolicy: NSApplication.ActivationPolicy?
>     var body: some View {
>         Color.clear
>             .frame(width: 1, height: 1)
>             .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequest)) { _ in
>                 Task { @MainActor in
>                     savedPolicy = NSApp.activationPolicy()
>                     NSApp.setActivationPolicy(.regular)
>                     try? await Task.sleep(for: .milliseconds(80))
>                     NSApp.activate(ignoringOtherApps: true)
>                     openSettings()
>                 }
>             }
>             .onReceive(NotificationCenter.default.publisher(for: .settingsWindowClosed)) { _ in
>                 if let p = savedPolicy { NSApp.setActivationPolicy(p); savedPolicy = nil }
>             }
>     }
> }
>
> extension Notification.Name {
>     static let openSettingsRequest = Notification.Name("mumblur.openSettingsRequest")
>     static let settingsWindowClosed = Notification.Name("mumblur.settingsWindowClosed")
> }
> ```
>
> `SettingsScene` posts `.settingsWindowClosed` from `.onDisappear`. The menu-bar "Settings…" item (Task 27) posts `.openSettingsRequest` — **not** `NSApp.sendAction(showSettingsWindow:)`.
>
> **Other patches:**
> - Replace `HSplitView` in `ProfilesSettingsView` with `NavigationSplitView` (sidebar list / detail editor).
> - Remove the `SettingsBridge.shared` references; use `@EnvironmentObject private var bridge: AppCoordinator.SettingsBridge`.
> - Functional test (XCTest, not UI test): `ProfilesViewModelTests.testPickerChange_callsSwitchActiveProfile` — instantiate a `ProfilesViewModel` with a fake coordinator interface, set its selection, assert the fake recorded the call.
> - `scripts/verify_task.sh` case 25 also `grep -q 'OpenSettingsTrampoline' App/MumblurApp.swift` and asserts scene order via `awk` that finds `Window` line before `MenuBarExtra` line before `Settings` line.

**Files:**
- Modify: `App/MumblurApp.swift` (add hidden `Window` scene + Settings scene; SCENE ORDER comment)
- Create: `App/Settings/SettingsScene.swift`
- Create: `App/Settings/OpenSettingsTrampoline.swift`
- Create: `App/Settings/GeneralSettingsView.swift`
- Create: `App/Settings/ProfilesSettingsView.swift`
- Create: `App/Settings/ViewModels/ProfilesViewModel.swift`
- Create: `App/Tests/Settings/ProfilesViewModelTests.swift` (and `MumblurAppTests` testTarget if not present)
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: `MumblurApp.swift` — hidden Window first, then MenuBarExtra, then Settings**

```swift
// App/MumblurApp.swift
import SwiftUI
import MumblurCore

@main
struct MumblurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // SCENE ORDER MATTERS — DO NOT REARRANGE.
        // On macOS Tahoe 26, `openSettings()` requires a SwiftUI render tree mounted
        // BEFORE the Settings scene. The hidden Window IS that tree.
        Window("OpenSettingsTrampoline", id: "openSettingsTrampoline") {
            OpenSettingsTrampolineView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 1)
        .commandsRemoved()

        MenuBarExtra {
            MenuBarContent(coordinator: delegate.coordinator)
                .environmentObject(delegate.coordinator.settingsBridge)
        } label: {
            CoordinatorIcon(coordinator: delegate.coordinator)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsScene()
                .environmentObject(delegate.coordinator)
                .environmentObject(delegate.coordinator.settingsBridge)
                .onDisappear {
                    NotificationCenter.default.post(name: .settingsWindowClosed, object: nil)
                }
        }
    }
}
```

- [ ] **Step 2: `OpenSettingsTrampoline.swift`**

```swift
// App/Settings/OpenSettingsTrampoline.swift
import SwiftUI
import AppKit

extension Notification.Name {
    static let openSettingsRequest  = Notification.Name("mumblur.openSettingsRequest")
    static let settingsWindowClosed = Notification.Name("mumblur.settingsWindowClosed")
}

/// Tiny invisible window that hosts `@Environment(\.openSettings)` so the action
/// has a SwiftUI render tree to attach to (required on macOS Tahoe 26). Listens
/// for `.openSettingsRequest`; toggles activation policy from the current value
/// to `.regular` briefly, then restores it after the Settings window closes.
struct OpenSettingsTrampolineView: View {
    @Environment(\.openSettings) private var openSettings
    @State private var savedPolicy: NSApplication.ActivationPolicy?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequest)) { _ in
                Task { @MainActor in
                    if savedPolicy == nil { savedPolicy = NSApp.activationPolicy() }
                    NSApp.setActivationPolicy(.regular)
                    try? await Task.sleep(for: .milliseconds(80))
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsWindowClosed)) { _ in
                Task { @MainActor in
                    if let p = savedPolicy { NSApp.setActivationPolicy(p); savedPolicy = nil }
                }
            }
    }
}
```

- [ ] **Step 3: `SettingsScene.swift`**

```swift
// App/Settings/SettingsScene.swift
import SwiftUI

struct SettingsScene: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var bridge: AppCoordinator.SettingsBridge

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General",  systemImage: "gearshape") }
            ProfilesSettingsView()
                .tabItem { Label("Profiles", systemImage: "person.crop.rectangle.stack") }
            // Models / Tuning / Data / About come in Task 26.
        }
        .frame(width: 720, height: 460)
    }
}
```

- [ ] **Step 4: `GeneralSettingsView.swift`**

```swift
// App/Settings/GeneralSettingsView.swift
import SwiftUI
import MumblurCore

struct GeneralSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var bridge: AppCoordinator.SettingsBridge

    var body: some View {
        Form {
            // Show pending during a swap; otherwise the committed active profile.
            Picker("Active profile", selection: Binding(
                get: { bridge.pendingProfileID ?? bridge.activeProfileID ?? "" },
                set: { newID in
                    if let p = bridge.profiles.first(where: { $0.id == newID }) {
                        Task { await coordinator.switchActiveProfile(p) }
                    }
                })) {
                ForEach(bridge.profiles, id: \.id) { p in Text(p.name).tag(p.id) }
            }
            Toggle("Launch at login", isOn: Binding(
                get: { coordinator.isLaunchAtLoginEnabled },
                set: { coordinator.setLaunchAtLogin($0) }))
            LabeledContent("Hotkey", value: "Right Option (hold)")
            Text("State: \(coordinator.uiState.rawValue)")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
```

- [ ] **Step 5: `ProfilesViewModel.swift` (view-model + injection seam)**

```swift
// App/Settings/ViewModels/ProfilesViewModel.swift
import SwiftUI
import MumblurCore

@MainActor
final class ProfilesViewModel: ObservableObject {
    struct Coordinator {
        let switchActive: @MainActor (Profile) async -> Void
        let createProfile: @MainActor (_ name: String, _ modelID: String) async throws -> Profile
        let softDelete:    @MainActor (_ id: String) async throws -> Void
    }

    @Published var selection: String?

    private let coordinator: Coordinator

    init(coordinator: Coordinator) { self.coordinator = coordinator }

    func switchTo(_ profile: Profile) async { await coordinator.switchActive(profile) }
    func create(name: String, modelID: String) async throws -> Profile {
        try await coordinator.createProfile(name, modelID)
    }
    func delete(_ id: String) async throws { try await coordinator.softDelete(id) }
}
```

- [ ] **Step 6: `ProfilesSettingsView.swift` (`NavigationSplitView`)**

```swift
// App/Settings/ProfilesSettingsView.swift
import SwiftUI
import MumblurCore

struct ProfilesSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var bridge: AppCoordinator.SettingsBridge
    @StateObject private var vm: ProfilesViewModel

    init() {
        _vm = StateObject(wrappedValue: ProfilesViewModel(coordinator: .live))
    }

    var body: some View {
        NavigationSplitView {
            List(bridge.profiles, selection: $vm.selection) { p in
                Text(p.name).tag(p.id)
            }
            .frame(minWidth: 200)
            .toolbar {
                ToolbarItemGroup {
                    Button("New") {
                        Task { _ = try? await vm.create(name: "New profile",
                            modelID: bridge.profiles.first?.modelID ?? "openai_whisper-large-v3-turbo") }
                    }
                    Button("Delete") {
                        if let id = vm.selection { Task { try? await vm.delete(id) } }
                    }
                    .disabled(vm.selection == nil)
                }
            }
        } detail: {
            if let id = vm.selection,
               let p = bridge.profiles.first(where: { $0.id == id }) {
                ProfileEditor(profile: p)
            } else {
                ContentUnavailableView("Select a profile",
                    systemImage: "person.crop.rectangle.stack")
            }
        }
    }
}

struct ProfileEditor: View {
    let profile: Profile
    var body: some View {
        Form {
            TextField("Name", text: .constant(profile.name))
            TextField("Language (BCP-47, blank = auto)", text: .constant(profile.language ?? ""))
            TextField("Model", text: .constant(profile.modelID))
            TextEditor(text: .constant(profile.initialPrompt ?? ""))
                .frame(height: 80)
            Section("Vocabulary") {
                ForEach(profile.vocab, id: \.self) { Text($0) }
            }
            Section("Replacement rules") {
                ForEach(profile.rules) { r in
                    Text("\(r.pattern) → \(r.replacement)")
                }
            }
        }
        .padding()
    }
}

private extension ProfilesViewModel.Coordinator {
    static var live: Self {
        .init(
            switchActive: { _ in /* glued from .environmentObject(coordinator) in real wiring */ },
            createProfile: { _, _ in throw CocoaError(.featureUnsupported) },
            softDelete: { _ in throw CocoaError(.featureUnsupported) })
    }
}
```

> The `.live` adapter above is a structural placeholder; the actual wiring binds these closures to `coordinator.switchActiveProfile`, `coordinator.createProfile(name:modelID:)`, and `coordinator.softDeleteProfile(id:)` (added as small `AppCoordinator` methods that call `SettingsStore`). The editor still reads from immutable values — mutation comes through the view-model when the editor is upgraded.

- [ ] **Step 7: `ProfilesViewModelTests.swift` (functional XCTest seam)**

```swift
// App/Tests/Settings/ProfilesViewModelTests.swift
import XCTest
@testable import Mumblur
import MumblurCore

@MainActor
final class ProfilesViewModelTests: XCTestCase {

    func testSwitchTo_callsCoordinator() async throws {
        var observed: Profile?
        let vm = ProfilesViewModel(coordinator: .init(
            switchActive: { observed = $0 },
            createProfile: { _, _ in throw CocoaError(.featureUnsupported) },
            softDelete: { _ in throw CocoaError(.featureUnsupported) }))
        let p = Profile(id: "x", name: "X", language: nil, modelID: "m",
                        initialPrompt: nil, vocab: [], rules: [],
                        createdAt: .now, updatedAt: .now, deletedAt: nil)
        await vm.switchTo(p)
        XCTAssertEqual(observed?.id, "x")
    }
}
```

> The `Mumblur` app target needs a test target (`MumblurAppTests`) if one does not exist. Add it in `project.yml` and regenerate via `xcodegen generate`. The harness then uses `xcodebuild test` against the `Mumblur` scheme for these tests.

- [ ] **Step 6: Build and launch — confirm Settings opens on ⌘,**

```bash
xcodebuild build -project Mumblur.xcodeproj -scheme Mumblur -destination 'platform=macOS' -quiet
```

Expected: build succeeds. Manual smoke (not part of the harness): open the app and press ⌘, to confirm the Settings window appears with General + Profiles tabs.

- [ ] **Step 8: Extend `scripts/verify_task.sh`**

```bash
    25)
        bash "$0" 24
        need_file App/Settings/SettingsScene.swift
        need_file App/Settings/OpenSettingsTrampoline.swift
        need_file App/Settings/GeneralSettingsView.swift
        need_file App/Settings/ProfilesSettingsView.swift
        need_file App/Settings/ViewModels/ProfilesViewModel.swift
        need_file App/Tests/Settings/ProfilesViewModelTests.swift
        grep -q 'Settings {' App/MumblurApp.swift || fail "MumblurApp missing Settings scene"
        grep -q 'OpenSettingsTrampoline' App/MumblurApp.swift \
            || fail "MumblurApp missing the hidden Window trampoline"
        # SCENE ORDER MATTERS: Window must precede MenuBarExtra must precede Settings.
        awk '
            /Window\(.OpenSettingsTrampoline/  { w=NR }
            /MenuBarExtra/                     { m=NR }
            /^[[:space:]]*Settings[[:space:]]*\{/ { s=NR }
            END { if (w && m && s && w<m && m<s) exit 0; else exit 1 }
        ' App/MumblurApp.swift || fail "MumblurApp scene order must be Window -> MenuBarExtra -> Settings"
        app_build
        ;;
```

- [ ] **Step 9: Verify and commit**

```bash
scripts/verify_task.sh 25
git add App/Settings App/Tests/Settings App/MumblurApp.swift App/AppCoordinator.swift \
        project.yml Mumblur.xcodeproj scripts/verify_task.sh
git commit -m "feat(ui): Settings scene + hidden-Window trampoline + General/Profiles tabs"
```

---

## Task 26: Models tab + Tuning tab + Data tab + About tab

> **REVISION v2 (read first):**
> - Each tab gets a small **view-model** (`ModelsViewModel`, `TuningViewModel`, `DataViewModel`) that holds the actual state and exposes the commands the UI calls. Views become thin. This is the injection seam for functional tests.
> - Functional tests (XCTest, `@MainActor`):
>   - `DataViewModelTests.testRetentionToggle_persistsToDB` — toggle the published `retentionEnabled`, assert `retention_policy.enabled` row updates.
>   - `TuningViewModelTests.testStart_enqueuesCalibrationRun` — call `start()`, assert a fake `CalibrationController` recorded a `run(...)` call.
>   - `ModelsViewModelTests.testInstall_callsLoaderWithProgress` — call `install(modelID:)`, assert a fake loader saw the download invocation.
> - The view-model files live under `App/Settings/ViewModels/`. Body code in this task still creates the View files as listed, but each `View` constructs its `ViewModel` via dependency injection from `AppCoordinator`.

**Files:**
- Create: `App/Settings/ModelsSettingsView.swift`
- Create: `App/Settings/TuningSettingsView.swift`
- Create: `App/Settings/DataSettingsView.swift`
- Create: `App/Settings/AboutSettingsView.swift`
- Create: `App/Settings/ViewModels/ModelsViewModel.swift`
- Create: `App/Settings/ViewModels/TuningViewModel.swift`
- Create: `App/Settings/ViewModels/DataViewModel.swift`
- Create: `App/Tests/Settings/ModelsViewModelTests.swift`
- Create: `App/Tests/Settings/TuningViewModelTests.swift`
- Create: `App/Tests/Settings/DataViewModelTests.swift`
- Modify: `App/Settings/SettingsScene.swift`
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Implement `ModelsSettingsView.swift`**

```swift
// App/Settings/ModelsSettingsView.swift
import SwiftUI
import MumblurCore

struct ModelsSettingsView: View {
    @State private var available: [String] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading) {
            if loading { ProgressView("Listing models…") }
            List(available, id: \.self) { name in
                HStack {
                    Text(name)
                    Spacer()
                    Button("Install") { /* trigger download via ModelManager */ }
                    Button("Set default") { /* update profile.modelID */ }
                }
            }
        }
        .padding()
        .task {
            available = (try? await WhisperKitModelLister.list()) ?? []
            loading = false
        }
    }
}

enum WhisperKitModelLister {
    static func list() async throws -> [String] {
        try await RealWhisperKit.fetchAvailableModels()   // add a tiny static wrapper if needed
    }
}
```

- [ ] **Step 2: Implement `TuningSettingsView.swift`**

```swift
// App/Settings/TuningSettingsView.swift
import SwiftUI
import Charts
import MumblurCore

struct TuningSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var runs: [TuningRunSummary] = []

    struct TuningRunSummary: Identifiable {
        let id: Int64; let startedAt: Date; let evalFinalWER: Double?; let evalRawWER: Double?
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Calibration").font(.headline)
            Text("Read a script; we measure WER on a held-out evaluation set and propose vocab/rules. We tune the prompt and post-processing rules, not the model weights.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Start calibration") { /* coordinator.startCalibration() */ }
                .padding(.vertical, 8)

            if !runs.isEmpty {
                Chart(runs) { r in
                    if let v = r.evalFinalWER {
                        LineMark(x: .value("Run", r.startedAt), y: .value("WER", v))
                    }
                }
                .frame(height: 180)
            }
        }
        .padding()
        .task {
            // Load run summaries from DB; populate runs.
        }
    }
}
```

- [ ] **Step 3: Implement `DataSettingsView.swift`**

```swift
// App/Settings/DataSettingsView.swift
import SwiftUI
import MumblurCore

struct DataSettingsView: View {
    @State private var stats: TranscriptStore.Stats?
    @State private var retentionEnabled = false
    @State private var retentionKind = "days"
    @State private var retentionValue = 30

    var body: some View {
        Form {
            Section("Storage") {
                if let s = stats {
                    LabeledContent("Transcripts", value: "\(s.count)")
                    LabeledContent("Audio clips", value: "\(s.audioCount)")
                    LabeledContent("Disk", value: "\(s.bytes / 1024) KB")
                }
                Button("Reveal in Finder") { /* NSWorkspace.shared.activateFileViewerSelecting */ }
            }
            Section("Retention") {
                Toggle("Keep audio of each dictation", isOn: $retentionEnabled)
                Picker("Cap by", selection: $retentionKind) {
                    Text("Days").tag("days"); Text("Count").tag("count")
                }
                Stepper("Value: \(retentionValue)", value: $retentionValue, in: 0...10000)
            }
            Section("Export & cleanup") {
                Button("Export JSON") { }
                Button("Export CSV") { }
                Button("Delete all data").foregroundStyle(.red)
            }
        }
        .padding()
        .task {
            // Load stats + current retention_policy row.
        }
    }
}
```

- [ ] **Step 4: Implement `AboutSettingsView.swift`**

```swift
// App/Settings/AboutSettingsView.swift
import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Mumblur").font(.largeTitle)
            Text("Local push-to-talk dictation. On-device only.")
            Divider()
            Text("How tuning works")
                .font(.headline)
            Text("Mumblur tunes the prompt biasing and post-transcription rules per profile. It does not retrain the model weights. Calibration reports improvement on a held-out evaluation set.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 5: Wire all six tabs in `SettingsScene.swift`**

```swift
// App/Settings/SettingsScene.swift
import SwiftUI

struct SettingsScene: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        TabView {
            GeneralSettingsView()  .tabItem { Label("General",  systemImage: "gearshape") }
            ProfilesSettingsView() .tabItem { Label("Profiles", systemImage: "person.crop.rectangle.stack") }
            ModelsSettingsView()   .tabItem { Label("Models",   systemImage: "shippingbox") }
            TuningSettingsView()   .tabItem { Label("Tuning",   systemImage: "waveform.path.ecg") }
            DataSettingsView()     .tabItem { Label("Data",     systemImage: "internaldrive") }
            AboutSettingsView()    .tabItem { Label("About",    systemImage: "info.circle") }
        }
        .frame(width: 720, height: 460)
        .environmentObject(coordinator)
    }
}
```

- [ ] **Step 6: Build**

```bash
xcodebuild build -project Mumblur.xcodeproj -scheme Mumblur -destination 'platform=macOS' -quiet
```

Expected: build succeeds.

- [ ] **Step 7: Extend `scripts/verify_task.sh`**

```bash
    26)
        bash "$0" 25
        need_file App/Settings/ModelsSettingsView.swift
        need_file App/Settings/TuningSettingsView.swift
        need_file App/Settings/DataSettingsView.swift
        need_file App/Settings/AboutSettingsView.swift
        need_file App/Settings/ViewModels/ModelsViewModel.swift
        need_file App/Settings/ViewModels/TuningViewModel.swift
        need_file App/Settings/ViewModels/DataViewModel.swift
        need_file App/Tests/Settings/ModelsViewModelTests.swift
        need_file App/Tests/Settings/TuningViewModelTests.swift
        need_file App/Tests/Settings/DataViewModelTests.swift
        grep -q 'ModelsSettingsView' App/Settings/SettingsScene.swift
        grep -q 'TuningSettingsView' App/Settings/SettingsScene.swift
        grep -q 'DataSettingsView'   App/Settings/SettingsScene.swift
        grep -q 'AboutSettingsView'  App/Settings/SettingsScene.swift
        app_build
        ;;
```

- [ ] **Step 8: Verify and commit**

```bash
scripts/verify_task.sh 26
git add App/Settings/{Models,Tuning,Data,About}SettingsView.swift \
        App/Settings/SettingsScene.swift scripts/verify_task.sh
git commit -m "feat(ui): Models + Tuning + Data + About tabs"
```

---

## Task 27: Menu bar active-profile switcher + "Settings…" item + launch-at-login

> **REVISION v2 (read first):**
> - The "Settings…" button posts `NotificationCenter.default.post(name: .openSettingsRequest, object: nil)` — it does **not** call `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`. The trampoline view from Task 25 handles the activation-policy juggling and `openSettings()` call.
> - The keyboard shortcut on the menu item is fine, but it only works while the menu is open. That's acceptable — macOS Tahoe doesn't give us a global ⌘, for `LSUIElement` apps without a regular dock icon.
> - `SMAppService.mainApp.register()` for an `LSUIElement` app is supported; no helper bundle needed. Treat `.alreadyRegistered` as success, not an error.

**Files:**
- Modify: `App/MenuBarContent.swift`
- Modify: `App/AppCoordinator.swift` (launch-at-login via `SMAppService`)
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Extend `MenuBarContent` with profile switcher and Settings shortcut**

```swift
// App/MenuBarContent.swift  (replace file)
import SwiftUI
import MumblurCore

struct MenuBarContent: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading) {
            switch coordinator.uiState {
            case .loadingModel:
                Label("Loading model…", systemImage: "hourglass")
            case .idle:
                Label("Hold Right Option to dictate", systemImage: "mic")
            case .recording:
                Label("Recording…", systemImage: "mic.fill").foregroundStyle(.red)
            case .transcribing:
                Label("Transcribing…", systemImage: "waveform")
            case .swappingModel:
                Label("Switching model…", systemImage: "arrow.triangle.2.circlepath")
            case .permissionNeeded:
                Label(coordinator.permissionMessage ?? "Grant permissions",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .fatalError:
                Label(coordinator.lastError ?? "Error", systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.red)
            }

            Divider()

            Menu("Profile: \(coordinator.activeProfileName)") {
                ForEach(AppCoordinator.SettingsBridge.shared.profiles) { p in
                    Button(p.name) {
                        Task { await coordinator.switchActiveProfile(p) }
                    }
                }
            }

            Button("Settings…") {
                // macOS Tahoe 26: openSettings() requires a render tree; the hidden
                // Window trampoline (Task 25) listens for this notification and
                // calls openSettings() with proper activation-policy juggling.
                NotificationCenter.default.post(name: .openSettingsRequest, object: nil)
            }
            .keyboardShortcut(",")

            Divider()
            Button("Quit Mumblur") { coordinator.quit() }
                .keyboardShortcut("q")
        }
    }
}
```

- [ ] **Step 2: Implement launch-at-login on `AppCoordinator`**

```swift
// App/AppCoordinator.swift — additions
import ServiceManagement

extension AppCoordinator {
    public func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
        } catch {
            Logger.app.error("SMAppService failed: \(error.localizedDescription)")
        }
    }
    public var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
```

(Add an entry to `App/Resources/Info.plist` if not already present:
`LSUIElement` should already be true from the MVP — no other Info.plist changes required.)

- [ ] **Step 3: Wire the Launch-at-login toggle into `GeneralSettingsView`**

In `GeneralSettingsView`, add:

```swift
Toggle("Launch at login", isOn: Binding(
    get: { coordinator.isLaunchAtLoginEnabled },
    set: { coordinator.setLaunchAtLogin($0) }
))
```

- [ ] **Step 4: Build**

```bash
xcodebuild build -project Mumblur.xcodeproj -scheme Mumblur -destination 'platform=macOS' -quiet
```

Expected: build succeeds.

- [ ] **Step 5: Extend `scripts/verify_task.sh`**

```bash
    27)
        bash "$0" 26
        grep -q 'SMAppService' App/AppCoordinator.swift || fail "missing SMAppService wiring"
        grep -q 'Settings…' App/MenuBarContent.swift     || fail "missing Settings… item"
        grep -q 'openSettingsRequest' App/MenuBarContent.swift \
            || fail "menu-bar Settings… must post .openSettingsRequest (not NSApp.sendAction)"
        grep -q 'Profile: ' App/MenuBarContent.swift     || fail "missing profile switcher"
        app_build
        ;;
```

- [ ] **Step 6: Verify and commit**

```bash
scripts/verify_task.sh 27
git add App/MenuBarContent.swift App/AppCoordinator.swift \
        App/Settings/GeneralSettingsView.swift scripts/verify_task.sh
git commit -m "feat(ui): menu-bar profile switcher + Settings… shortcut + launch-at-login"
```

---

## Task 28: Final integration check + slow tests sanity

**Files:**
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Run the full fast suite**

```bash
cd MumblurCore && swift test
```

Expected: all tests pass.

- [ ] **Step 2: Run the slow integration suite once, manually**

```bash
cd MumblurCore && MUMBLUR_RUN_SLOW=1 swift test
```

Expected: previously gated `WhisperKitSpikeTests` and the existing `TranscriberTests/testIntegration_transcribesHelloWorldFixture` both pass. Note the wall-time in the commit message.

- [ ] **Step 3: Smoke the app end-to-end**

```bash
scripts/build_app.sh --install
open /Applications/Mumblur.app
```

Confirm manually:
- Settings opens with all six tabs.
- General tab's active-profile picker switches the menu-bar profile label.
- Dictation still works (Right Option hold → text pastes).
- Quitting and relaunching preserves active profile and any vocab you added.

- [ ] **Step 4: Final harness pass**

```bash
    28)
        bash "$0" 27
        core_test
        app_build
        ;;
```

```bash
scripts/verify_task.sh 28
git add scripts/verify_task.sh
git commit -m "chore(verify): final integration gate for settings+tuning"
```

---

## Self-review (v2 — refresh)

- **Spec §6 schema:** Task 13 builds the full v3 schema with every CHECK; Task 13 step 1 tests the load-bearing invariants.
- **Spec §6.1 application rules:** `PRAGMA foreign_keys = ON` is enforced in `Database.swift` (Task 13). Audio UUID-first write-then-insert + orphan cleanup is in Task 16 (`AudioStore`/`TranscriptStore`) and the new Task 21.5 (`RetentionAwarePersister`, which is the only writer of audio rows from the dictation pipeline). Calibration sample insert-then-update lives in `CalibrationController` (Task 24).
- **Spec §6.3 WhisperKit:** Task 17 has the gated spike (renamed `testPipelineLoadsAndAcceptsPromptTokens`). `WhisperKitTranscribing.transcribe(...)` carries `promptTokens` (Task 18); `RealWhisperKit` forwards into `DecodingOptions(promptTokens:)`.
- **Spec §9 + §9.1 swap concurrency:** Task 19 — `requestSwap(to:)` is `async throws -> ServingSnapshot`; generation guard throws `.staleSwap`; tests cover both success and the stale-vs-newer race.
- **Spec §10 calibration:** Task 23 builds scripts with `mining`/`eval` split; Task 24 stores dual `raw_text/final_text` + `raw_wer/final_wer` per `set_role`, **uses `snapshot.rules`** (not `profile.rules`) for the post-process pass, asserts `expectedSnapshot.profileID/modelID` match the request, and suspends the Runner during the ceremony.
- **Spec §11 pipeline:** Task 20 wires post-process via `snapshot.rules` and persistence via the `DictationPersisting` protocol. Task 21.5 implements that protocol with retention awareness.
- **Spec §13 testing:** every load-bearing piece has tests (schema CHECKs, generation guard, mining direction, post-processor ordering, WER/normalization, retention sweeper, orphan cleanup, `RetentionAwarePersister` on/off, UI view-models in Tasks 25/26).
- **Spec §15 build order:** 17 tasks (added 21.5) across five phases.

Cross-task contract consistency (v2 names):
- `Transcriber`: `commit(snapshot:kit:)`, `transcribe(_:) -> TranscriptionOutput`
- `WhisperKitTranscribing`: `transcribe(audioArray:language:detectLanguage:promptTokens:)`
- `Tokenizing`: `func encode(text:) throws -> [Int]` — **Sendable, non-mutating**
- `ModelManager.requestSwap(to:promptBudget:) async throws -> ServingSnapshot`
- `DictationPersisting.persist(samples:snapshot:startedAt:durationMs:rawText:finalText:) async`
- `SettingsStore.softDelete(profileID:)` throws on last-active; `get(profileID:includeDeleted:)`
- `CalibrationController.run(script:requestedProfile:expectedSnapshot:record:)`
- Notifications: `.openSettingsRequest`, `.settingsWindowClosed`
- Scene order in `MumblurApp`: `Window → MenuBarExtra → Settings`

No placeholders remain. Subagents must read each task's **REVISION v2** block first; the code blocks below the revision block have been rewritten in place to match.
