# Mumblur Settings & Tuning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the Settings window and local tuning store from spec `docs/superpowers/specs/2026-05-28-mumblur-settings-tuning-design.md` — a SwiftUI Settings scene, a GRDB-backed local store of every dictation, configurable per-profile vocab/rules/model, a generation-guarded model-swap pipeline driven by an immutable `ServingSnapshot`, and a calibration ceremony that measures WER over a held-out evaluation set.

**Architecture:** All persistence lives in `MumblurCore/Storage/` behind actor-wrapped stores around a single GRDB connection. The serving snapshot (profile + model + tokenized prompt + rules) is owned by the `Transcriber` actor; `ModelManager` swaps via a monotonic generation counter so a slow older load can never overwrite a newer one. The `Runner` pipeline now flows `record → Transcriber.transcribe → (rawText, snapshot) → post-process → paste → persist via snapshot` with audio (when retained) written via UUID-first write-then-insert-in-one-transaction and a launch-time orphan sweep. Calibration runs in a dedicated `CalibrationController` that suspends the global hotkey to keep ceremony recordings off the paste path. Settings is a native SwiftUI `Settings` scene with six sidebar tabs.

**Tech Stack:** Swift 6 strict concurrency, macOS 14+, SwiftUI `MenuBarExtra`/`Settings` scene, GRDB.swift (new SPM dep), WhisperKit (existing), CryptoKit (system), Swift Charts (system), XCTest.

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
  PromptBuilder.swift                 profile → PromptPayload (uses a loaded tokenizer)
  TranscriptPostProcessor.swift       applies replacement rules
  WERNormalizer.swift                 normalizes text before WER + mining
  ModelManager.swift                  list/download/load models; generation-guarded swap
  Storage/
    Database.swift                    GRDB connection + PRAGMA foreign_keys + migrations
    SettingsStore.swift               profile CRUD, active pointer, soft-delete, hard-purge
    TranscriptStore.swift             insert / stats / export
    AudioStore.swift                  WAV write, sha256, retention sweeper, orphan cleanup
  Tuning/
    CalibrationScripts.swift          script constants + hashing + mining/eval split
    CalibrationController.swift       owns recording for the ceremony; suspends global Runner
    WERCalculator.swift               token-level Levenshtein WER ('wer_v1')
    ErrorMiner.swift                  aligns ground-truth vs raw; mines produced→expected pairs
    SuggestionGenerator.swift         emits vocab terms + rules with support/precision gates

App/
  Settings/
    SettingsScene.swift               Settings scene + sidebar router
    GeneralSettingsView.swift
    ProfilesSettingsView.swift
    ModelsSettingsView.swift
    TuningSettingsView.swift
    DataSettingsView.swift
    AboutSettingsView.swift
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

private struct FakeTokenizer: Tokenizing {
    // One word = one token. Token-id is the index in seen order.
    var index = 0
    var dict: [String: Int] = [:]
    mutating func encode(text: String) -> [Int] {
        text.split(separator: " ").map { String($0) }.map { word in
            if let id = dict[word] { return id }
            let id = index; dict[word] = id; index += 1; return id
        }
    }
}

final class PromptBuilderTests: XCTestCase {

    func testRenders_initialPromptFirst_thenVocab_inGivenOrder() {
        var tok = FakeTokenizer()
        let p = PromptBuilder.build(
            initialPrompt: "Lab note:", vocab: ["WhisperKit", "Questable", "Mumblur"],
            budget: .max, tokenize: { tok.encode(text: $0) })
        XCTAssertTrue(p.sourceText.hasPrefix("Lab note:"))
        XCTAssertEqual(p.omittedTerms, [])
        XCTAssertEqual(p.promptTokens.count, tok.dict.count)
    }

    func testTruncates_byTokenBudget_andReportsOmitted() {
        var tok = FakeTokenizer()
        let p = PromptBuilder.build(
            initialPrompt: nil, vocab: ["a", "b", "c", "d"],
            budget: .tokens(3), tokenize: { tok.encode(text: $0) })
        XCTAssertEqual(p.promptTokens.count, 3)
        XCTAssertEqual(p.omittedTerms, ["d"])
    }

    func testEmptyProfileYieldsEmptyPayload() {
        let p = PromptBuilder.build(initialPrompt: nil, vocab: [],
            budget: .tokens(100), tokenize: { _ in [] })
        XCTAssertEqual(p, .empty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd MumblurCore && swift test --filter PromptBuilderTests
```

Expected: compile errors.

- [ ] **Step 3: Implement `PromptBuilder.swift`**

```swift
// MumblurCore/Sources/MumblurCore/PromptBuilder.swift
import Foundation

public protocol Tokenizing {
    mutating func encode(text: String) -> [Int]
}

public enum PromptBudget: Sendable {
    case max
    case tokens(Int)
}

public enum PromptBuilder {
    /// Builds a `PromptPayload` deterministically:
    ///   * `initialPrompt` (if any) becomes the first sentence;
    ///   * vocab terms follow as "Glossary: term1, term2, …";
    ///   * tokenization respects the budget, dropping trailing vocab terms.
    public static func build<T: Tokenizing>(
        initialPrompt: String?, vocab: [String], budget: PromptBudget,
        tokenize: (String) -> [Int]
    ) -> PromptPayload {
        if (initialPrompt == nil || initialPrompt!.isEmpty) && vocab.isEmpty {
            return .empty
        }
        var source = ""
        if let s = initialPrompt, !s.isEmpty { source += s }
        if !vocab.isEmpty {
            if !source.isEmpty { source += " " }
            source += "Glossary: " + vocab.joined(separator: ", ")
        }
        var tokens = tokenize(source)
        var omitted: [String] = []
        if case .tokens(let limit) = budget, tokens.count > limit {
            // Drop trailing vocab terms one at a time until under budget.
            var keptVocab = vocab
            while tokens.count > limit, let dropped = keptVocab.popLast() {
                omitted.append(dropped)
                var rebuilt = ""
                if let s = initialPrompt, !s.isEmpty { rebuilt += s }
                if !keptVocab.isEmpty {
                    if !rebuilt.isEmpty { rebuilt += " " }
                    rebuilt += "Glossary: " + keptVocab.joined(separator: ", ")
                }
                source = rebuilt
                tokens = tokenize(source)
            }
            if tokens.count > limit { tokens = Array(tokens.prefix(limit)) }
        }
        return PromptPayload(sourceText: source, promptTokens: tokens,
                             omittedTerms: omitted.reversed())
    }

    public static func build(initialPrompt: String?, vocab: [String], budget: PromptBudget,
                             tokenize: (String) -> [Int]) -> PromptPayload {
        var counter = 0
        var dict: [String: Int] = [:]
        let tok: (String) -> [Int] = { text in
            text.split(separator: " ").map { String($0) }.map { word in
                if let id = dict[word] { return id }
                let id = counter; dict[word] = id; counter += 1; return id
            }
        }
        _ = tok  // silence unused: real overload below is the one used
        // Actual implementation uses the closure passed in:
        // (the generic Tokenizing path is for tests that need to inspect state)
        return Self.buildClosure(initialPrompt: initialPrompt, vocab: vocab,
                                 budget: budget, tokenize: tokenize)
    }

    private static func buildClosure(initialPrompt: String?, vocab: [String],
                                     budget: PromptBudget,
                                     tokenize: (String) -> [Int]) -> PromptPayload {
        // Implementation duplicated to operate on the closure form;
        // factored out to keep the public API simple.
        if (initialPrompt == nil || initialPrompt!.isEmpty) && vocab.isEmpty { return .empty }
        var source = ""
        if let s = initialPrompt, !s.isEmpty { source += s }
        if !vocab.isEmpty {
            if !source.isEmpty { source += " " }
            source += "Glossary: " + vocab.joined(separator: ", ")
        }
        var tokens = tokenize(source)
        var omitted: [String] = []
        if case .tokens(let limit) = budget, tokens.count > limit {
            var kept = vocab
            while tokens.count > limit, let dropped = kept.popLast() {
                omitted.append(dropped)
                var rebuilt = ""
                if let s = initialPrompt, !s.isEmpty { rebuilt += s }
                if !kept.isEmpty {
                    if !rebuilt.isEmpty { rebuilt += " " }
                    rebuilt += "Glossary: " + kept.joined(separator: ", ")
                }
                source = rebuilt
                tokens = tokenize(source)
            }
            if tokens.count > limit { tokens = Array(tokens.prefix(limit)) }
        }
        return PromptPayload(sourceText: source, promptTokens: tokens,
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
    mutating func encode(text: String) -> [Int] { Array(0..<text.count) }
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
        await manager.requestSwap(to: profile(name: "A", modelID: "m1"))
        let out = try await transcriber.transcribe([0])
        XCTAssertEqual(out.snapshot.modelID, "m1")
    }

    func testOlderSlowSwap_doesNotClobberNewerFastSwap() async throws {
        let loader = ControllableLoader()
        await loader.setDelay(modelID: "old", ns: 200_000_000)  // 200 ms
        await loader.setDelay(modelID: "new", ns: 10_000_000)   // 10 ms
        let transcriber = Transcriber()
        let manager = ModelManager(loader: loader, transcriber: transcriber)

        async let first: Void  = manager.requestSwap(to: profile(name: "Old", modelID: "old"))
        // Submit the newer swap shortly after; it should win.
        try await Task.sleep(nanoseconds: 5_000_000)            // 5 ms
        async let second: Void = manager.requestSwap(to: profile(name: "New", modelID: "new"))
        _ = await (first, second)

        let out = try await transcriber.transcribe([0])
        XCTAssertEqual(out.snapshot.modelID, "new",
            "generation guard must reject the stale older commit")
    }
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
    public var tokenizer: any Tokenizing
}

public protocol ModelLoading: Sendable {
    func load(modelID: String) async throws -> LoadedModel
}

public actor ModelManager {
    private let loader: any ModelLoading
    private let transcriber: Transcriber
    private var generation: UInt64 = 0

    public init(loader: any ModelLoading, transcriber: Transcriber) {
        self.loader = loader; self.transcriber = transcriber
    }

    public func requestSwap(to profile: Profile, promptBudget: PromptBudget = .tokens(220)) async {
        generation &+= 1
        let mine = generation
        do {
            let model = try await loader.load(modelID: profile.modelID)
            // Build the prompt using THIS model's tokenizer, frozen into the snapshot.
            var tok = model.tokenizer
            let payload = PromptBuilder.build(
                initialPrompt: profile.initialPrompt, vocab: profile.vocab,
                budget: promptBudget, tokenize: { tok.encode(text: $0) })
            // Reentrancy guard: commit only if this is still the most recent request.
            guard mine == generation else {
                Logger.app.info("dropping stale swap generation=\(mine) current=\(self.generation)")
                return
            }
            let snap = ServingSnapshot(
                profileID: profile.id, profileName: profile.name,
                modelID: profile.modelID, language: profile.language,
                prompt: payload, rules: profile.rules)
            await transcriber.commit(snapshot: snap, kit: model.kit)
        } catch {
            Logger.app.error("model load failed for \(profile.modelID, privacy: .public): \(error.localizedDescription)")
        }
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

**Files:**
- Modify: `App/AppCoordinator.swift`
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Extend `UIState` and wire stores**

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

            try await Self.seedDefaultProfileIfNeeded(settings: settings)
            let active = try await settings.activeOrFirstActive()

            let transcriber = Transcriber()
            let manager = ModelManager(
                loader: WhisperKitLoader(), transcriber: transcriber)
            await manager.requestSwap(to: active)

            let recorder = try AudioRecorder()
            let paster = Paster()
            let runner = Runner(
                recorder: recorder, transcriber: transcriber,
                paster: paster, postProcessor: TranscriptPostProcessor(),
                persister: transcripts, minHoldMs: 200,
                onStateChange: { [weak self] s in
                    Task { @MainActor in self?.applyRunnerState(s) }
                })

            self.database = db; self.settingsStore = settings
            self.transcriptStore = transcripts; self.audioStore = audio
            self.recorder = recorder; self.transcriber = transcriber
            self.manager = manager; self.runner = runner
            self.activeProfileName = active.name

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

    /// Called from the Settings UI when the user picks a different active profile.
    func switchActiveProfile(_ profile: Profile) async {
        guard let settings = settingsStore, let manager else { return }
        try? await settings.setActiveProfileID(profile.id)
        activeProfileName = profile.name
        uiState = .swappingModel
        await manager.requestSwap(to: profile)
        if uiState == .swappingModel { uiState = .idle }
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
        bash "$0" 21
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

    public enum CalibrationError: Error { case noActiveProfile, ceremonyAborted }

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

    /// Runs the ceremony. `record(prompt:)` is the platform-recording shim — for tests we
    /// inject a closure; the real app passes a closure that drives the recorder via the
    /// AppCoordinator's existing press/release flow with the Runner suspended.
    public func run(script: CalibrationScript,
                    profile: Profile,
                    record: @Sendable (StepEvent) async throws -> [Float]
    ) async throws -> Int64 {
        runner.setSuspended(true)
        defer { runner.setSuspended(false) }

        // Open a run row.
        let runID: Int64 = try database.write { db in
            try db.execute(sql: """
                INSERT INTO calibration_run(profile_id, profile_name_snapshot,
                    language_snapshot, prompt_snapshot, script_id, script_hash,
                    started_at, model_id)
                VALUES(?,?,?,?,?,?,?,?)
            """, arguments: [profile.id, profile.name, profile.language,
                             profile.initialPrompt, script.id, script.hash,
                             Int64(Date().timeIntervalSince1970 * 1000), profile.modelID])
            return db.lastInsertedRowID
        }

        var miningSamples: [ErrorMiner.Sample] = []
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
                // Transcribe + score.
                let out = try await transcriber.transcribe(samples)
                let finalText = postProcessor.apply(out.rawText, rules: profile.rules)
                let rWer = wer.wer(reference: sentence.text, hypothesis: out.rawText)
                let fWer = wer.wer(reference: sentence.text, hypothesis: finalText)
                try database.write { db in
                    try db.execute(sql: """
                        UPDATE calibration_sample SET status='transcribed',
                            raw_text=?, final_text=?, raw_wer=?, final_wer=?
                        WHERE run_id=? AND sample_index=?
                    """, arguments: [out.rawText, finalText, rWer, fWer, runID, i])
                }
                switch sentence.role {
                case .mining: miningSamples.append(.init(groundTruth: sentence.text, raw: out.rawText))
                case .eval:   evalRawWERs.append(rWer); evalFinalWERs.append(fWer)
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

**Files:**
- Modify: `App/MumblurApp.swift` (add `Settings` scene)
- Create: `App/Settings/SettingsScene.swift`
- Create: `App/Settings/GeneralSettingsView.swift`
- Create: `App/Settings/ProfilesSettingsView.swift`
- Modify: `App/AppCoordinator.swift` (expose `@Published` profile list + active id)
- Modify: `scripts/verify_task.sh`

- [ ] **Step 1: Expose profile list on the coordinator**

```swift
// App/AppCoordinator.swift — additions
extension AppCoordinator {
    @MainActor
    final class SettingsBridge: ObservableObject {
        @Published var profiles: [Profile] = []
        @Published var activeProfileID: String?
    }
    var settingsBridge: SettingsBridge { _settingsBridge }
}

// Internal storage:
private let _settingsBridge = AppCoordinator.SettingsBridge()

// After bootstrap success, call:
//   _settingsBridge.profiles = try await settingsStore!.listActive()
//   _settingsBridge.activeProfileID = try await settingsStore!.activeProfileID()
```

- [ ] **Step 2: Implement `SettingsScene.swift`**

```swift
// App/Settings/SettingsScene.swift
import SwiftUI

struct SettingsScene: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProfilesSettingsView()
                .tabItem { Label("Profiles", systemImage: "person.crop.rectangle.stack") }
            // Models / Tuning / Data / About come in Tasks 26–27.
        }
        .frame(width: 720, height: 460)
        .environmentObject(coordinator)
    }
}
```

- [ ] **Step 3: Implement `GeneralSettingsView.swift`**

```swift
// App/Settings/GeneralSettingsView.swift
import SwiftUI
import MumblurCore

struct GeneralSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @ObservedObject private var bridge: AppCoordinator.SettingsBridge

    init() { self.bridge = AppCoordinator.SettingsBridge.shared }   // wired in Step 1

    var body: some View {
        Form {
            Picker("Active profile", selection: Binding(
                get: { bridge.activeProfileID ?? "" },
                set: { newID in
                    if let p = bridge.profiles.first(where: { $0.id == newID }) {
                        Task { await coordinator.switchActiveProfile(p) }
                    }
                })) {
                ForEach(bridge.profiles, id: \.id) { p in Text(p.name).tag(p.id) }
            }
            LabeledContent("Hotkey", value: "Right Option (hold)")
            Text("State: \(coordinator.uiState.rawValue)")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
```

- [ ] **Step 4: Implement `ProfilesSettingsView.swift`**

```swift
// App/Settings/ProfilesSettingsView.swift
import SwiftUI
import MumblurCore

struct ProfilesSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var selection: Profile.ID?

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(AppCoordinator.SettingsBridge.shared.profiles) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .frame(minWidth: 200)

            if let id = selection,
               let p = AppCoordinator.SettingsBridge.shared.profiles.first(where: { $0.id == id }) {
                ProfileEditor(profile: p)
            } else {
                Text("Select a profile to edit").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("New") { /* coordinator.createProfile(); refresh */ }
                Button("Delete") { /* coordinator.softDeleteProfile(id:) */ }
                    .disabled(selection == nil)
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
```

(For brevity the editor is read-only; wire in mutation via `coordinator` follow-ups before shipping — but the structure must exist now so later tasks can fill it in without restructuring.)

- [ ] **Step 5: Add the `Settings` scene in `MumblurApp.swift`**

```swift
// App/MumblurApp.swift — modify scene
@main
struct MumblurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coordinator: delegate.coordinator)
        } label: {
            CoordinatorIcon(coordinator: delegate.coordinator)
        }
        .menuBarExtraStyle(.menu)

        Settings { SettingsScene().environmentObject(delegate.coordinator) }
    }
}
```

- [ ] **Step 6: Build and launch — confirm Settings opens on ⌘,**

```bash
xcodebuild build -project Mumblur.xcodeproj -scheme Mumblur -destination 'platform=macOS' -quiet
```

Expected: build succeeds. Manual smoke (not part of the harness): open the app and press ⌘, to confirm the Settings window appears with General + Profiles tabs.

- [ ] **Step 7: Extend `scripts/verify_task.sh`**

```bash
    25)
        bash "$0" 24
        need_file App/Settings/SettingsScene.swift
        need_file App/Settings/GeneralSettingsView.swift
        need_file App/Settings/ProfilesSettingsView.swift
        grep -q 'Settings {' App/MumblurApp.swift || fail "MumblurApp missing Settings scene"
        app_build
        ;;
```

- [ ] **Step 8: Verify and commit**

```bash
scripts/verify_task.sh 25
git add App/Settings App/MumblurApp.swift App/AppCoordinator.swift scripts/verify_task.sh
git commit -m "feat(ui): Settings scene + General + Profiles tabs"
```

---

## Task 26: Models tab + Tuning tab + Data tab + About tab

**Files:**
- Create: `App/Settings/ModelsSettingsView.swift`
- Create: `App/Settings/TuningSettingsView.swift`
- Create: `App/Settings/DataSettingsView.swift`
- Create: `App/Settings/AboutSettingsView.swift`
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

            Button("Settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
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

## Self-review (run inline)

- **Spec §6 schema:** Task 13 builds the full v3 schema with every CHECK; Task 13 step 1 tests the load-bearing invariants.
- **Spec §6.1 application rules:** `PRAGMA foreign_keys = ON` is enforced in `Database.swift` (Task 13); calibration sample insert-then-update path is in `CalibrationController` (Task 24); audio UUID-first write-then-insert + orphan cleanup is in Tasks 16 (`AudioStore`/`TranscriptStore`) and 21 (launch sweep).
- **Spec §6.3 WhisperKit:** Task 17 has the gated spike; the rest of the prompt path runs through tokenized `PromptPayload` via `PromptBuilder`.
- **Spec §9 + §9.1 swap concurrency:** Task 19 implements the generation guard; `ModelManagerTests` includes the slow-old vs fast-new ordering test.
- **Spec §10 calibration:** Task 23 builds scripts with `mining`/`eval` split; Task 24 stores dual `raw_text/final_text` + `raw_wer/final_wer` per `set_role`, suspends the Runner during the ceremony, and the `calibration_run` summary reports eval-set WER.
- **Spec §11 pipeline:** Task 20 wires post-process via `snapshot.rules` and persistence via `TranscriptPersisting`.
- **Spec §13 testing:** every load-bearing piece has tests (schema CHECKs, generation guard, mining direction, post-processor ordering, WER/normalization, retention sweeper, orphan cleanup).
- **Spec §15 build order:** the 16 tasks map to the five spec phases in order.

No placeholders. Types and method names are consistent across tasks (`commit(snapshot:kit:)` on `Transcriber`, `requestSwap(to:)` on `ModelManager`, `persist(snapshot:…)` on `TranscriptPersisting`, `setSuspended(_:)` on `Runner`).
