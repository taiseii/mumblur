# LLM Transcript Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional, per-profile LLM cleanup stage that sends the raw Whisper transcript to a local OpenAI-compatible server (llama.cpp/Ollama/LM Studio/MLX) before the deterministic replacement-rule pass, failing open so dictation never breaks.

**Architecture:** A new `TranscriptEditing` protocol seam in `MumblurCore` with an `OpenAICompatibleEditor` actor, injected into `Runner` alongside the existing transcriber/paster/persister seams. Per-profile config (`enabled`, `prompt`) rides the frozen `ServingSnapshot`; machine-global server config (URL/model/timeout/master-enable) lives in the editor and is hot-swappable. The pipeline order is Whisper → LLM → rules → paste. Fail-open with a hard wall-clock timeout; `CancellationError` propagates so a cancelled worker never pastes.

**Tech Stack:** Swift 6 (strict concurrency), actors + `OSAllocatedUnfairLock`, GRDB (SQLite), `URLSession`, XCTest, SwiftUI (macOS menu-bar app).

**Reference spec:** `docs/superpowers/specs/2026-05-28-llm-transcript-editing-design.md`

---

## File Structure

**Create:**
- `MumblurCore/Sources/MumblurCore/LLMEditor.swift` — `TranscriptEditing` protocol, `LLMEditConfig`, `LLMServerConfig`, `NoOpEditor`, `OpenAICompatibleEditor` actor, timeout race helper.
- `MumblurCore/Sources/MumblurCore/Storage/MigrationsV2.swift` — `registerV2()` adding two profile columns.
- `MumblurCore/Tests/MumblurCoreTests/LLMEditorTests.swift` — editor unit tests (URLProtocol stub, fail-open, timeout, gates, URL normalization).
- `MumblurCore/Tests/MumblurCoreTests/Storage/MigrationsV2Tests.swift` — migration + new-column round-trip.
- `App/Settings/AISettingsView.swift` — the "AI Editing" settings tab view.
- `App/Settings/ViewModels/AIViewModel.swift` — view model + `Deps` for the AI tab.

**Modify:**
- `MumblurCore/Sources/MumblurCore/Profile.swift` — two new fields + defaulted init params.
- `MumblurCore/Sources/MumblurCore/ServingSnapshot.swift` — `llmEdit` field (defaulted) + `with(llmEdit:)` copy helper.
- `MumblurCore/Sources/MumblurCore/Runner.swift` — `editor` seam (defaulted to `NoOpEditor`), LLM stage in `doWork` with cancellation guard.
- `MumblurCore/Sources/MumblurCore/Transcriber.swift` — `updateLLMEdit(_:)` patch method.
- `MumblurCore/Sources/MumblurCore/ModelManager.swift` — resolve `llmEdit` into the snapshot.
- `MumblurCore/Sources/MumblurCore/Storage/SettingsStore.swift` — carry new columns in create/update/decoder; `llmServerConfig()` / `setLLMServerConfig(_:)`.
- `MumblurCore/Sources/MumblurCore/Storage/Database.swift:35` — register V2.
- `MumblurCore/Tests/MumblurCoreTests/RunnerTests.swift` — `FakeEditor` + ordering/fail-open/cancellation tests.
- `App/AppCoordinator.swift` — construct/inject editor in bootstrap; `setLLMServerConfig(_:)`; `updateProfileAISettings(...)`.
- `App/Settings/SettingsScene.swift:8-17` — register the new tab.

**Phasing:** Phases A–E are in `MumblurCore` + `App` wiring and are fully unit-testable with `swift test`. Phase F is SwiftUI and is verified by building the app and manual use. Phases A–D produce working, testable core software before any UI exists.

**Test commands:**
- Core tests: `swift test --package-path MumblurCore` (filter with `--filter <SuiteName>`)
- App build: delegate to the apple-platform-build-tools builder agent (it discovers the scheme); do not invent an `xcodebuild` invocation here.

---

## Phase A — Data model & migration

### Task A1: Profile gains LLM fields

**Files:**
- Modify: `MumblurCore/Sources/MumblurCore/Profile.swift`

- [ ] **Step 1: Add the two stored properties and defaulted init params**

In `Profile.swift`, add the properties after `rules` and add defaulted params to the init (defaults keep existing call sites compiling):

```swift
public struct Profile: Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var language: String?
    public var modelID: String
    public var initialPrompt: String?
    public var vocab: [String]
    public var rules: [ReplacementRule]
    public var llmEditEnabled: Bool
    public var llmEditPrompt: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: String, name: String, language: String?, modelID: String,
                initialPrompt: String?, vocab: [String], rules: [ReplacementRule],
                llmEditEnabled: Bool = false, llmEditPrompt: String? = nil,
                createdAt: Date, updatedAt: Date, deletedAt: Date?) {
        self.id = id; self.name = name; self.language = language
        self.modelID = modelID; self.initialPrompt = initialPrompt
        self.vocab = vocab; self.rules = rules
        self.llmEditEnabled = llmEditEnabled; self.llmEditPrompt = llmEditPrompt
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}
```

- [ ] **Step 2: Build to confirm no existing call site broke**

Run: `swift build --package-path MumblurCore`
Expected: builds clean (defaults absorb existing callers).

- [ ] **Step 3: Commit**

```bash
git add MumblurCore/Sources/MumblurCore/Profile.swift
git commit -m "feat(core): add llmEditEnabled/llmEditPrompt to Profile"
```

### Task A2: Migration V2 adds the columns

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/Storage/MigrationsV2.swift`
- Modify: `MumblurCore/Sources/MumblurCore/Storage/Database.swift:35`
- Test: `MumblurCore/Tests/MumblurCoreTests/Storage/MigrationsV2Tests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MigrationsV2Tests.swift
import XCTest
import GRDB
@testable import MumblurCore

final class MigrationsV2Tests: XCTestCase {
    func testV2_addsLLMColumns_withDefaults() throws {
        let db = try AppDatabase(location: .inMemory) // runMigrations() runs in init
        let (enabled, prompt): (Int, String?) = try db.write { d in
            try d.execute(sql: """
                INSERT INTO profile(id,name,model_id,created_at,updated_at)
                VALUES ('p','P','m',0,0)
            """)
            let row = try Row.fetchOne(d,
                sql: "SELECT llm_edit_enabled, llm_edit_prompt FROM profile WHERE id='p'")!
            return (row["llm_edit_enabled"], row["llm_edit_prompt"])
        }
        XCTAssertEqual(enabled, 0)
        XCTAssertNil(prompt)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MumblurCore --filter MigrationsV2Tests`
Expected: FAIL — `no such column: llm_edit_enabled`.

- [ ] **Step 3: Create the migration**

```swift
// MigrationsV2.swift
import GRDB

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

- [ ] **Step 4: Register it in `runMigrations()`**

In `Database.swift`, add the call immediately after `registerV1()`:

```swift
    public func runMigrations() throws {
        var migrator = DatabaseMigrator()
        migrator.registerV1()
        migrator.registerV2()
        try migrator.migrate(queue)
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path MumblurCore --filter MigrationsV2Tests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add MumblurCore/Sources/MumblurCore/Storage/MigrationsV2.swift \
        MumblurCore/Sources/MumblurCore/Storage/Database.swift \
        MumblurCore/Tests/MumblurCoreTests/Storage/MigrationsV2Tests.swift
git commit -m "feat(storage): migration v2 adds profile LLM-edit columns"
```

### Task A3: SettingsStore carries the new profile columns

**Files:**
- Modify: `MumblurCore/Sources/MumblurCore/Storage/SettingsStore.swift` (lines ~14-29 create, ~59-70 update, ~145-169 decoder)
- Test: `MumblurCore/Tests/MumblurCoreTests/Storage/SettingsStoreTests.swift` (existing file — add a test)

- [ ] **Step 1: Write the failing test**

Add to the existing `SettingsStoreTests`:

```swift
func testUpdate_roundTripsLLMEditFields() async throws {
    let db = try AppDatabase(location: .inMemory)
    let store = SettingsStore(database: db)
    var p = try await store.create(name: "Work", modelID: "m")
    p.llmEditEnabled = true
    p.llmEditPrompt = "Tidy it up"
    try await store.update(p)
    let back = try await store.get(profileID: p.id)
    XCTAssertEqual(back?.llmEditEnabled, true)
    XCTAssertEqual(back?.llmEditPrompt, "Tidy it up")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MumblurCore --filter SettingsStoreTests/testUpdate_roundTripsLLMEditFields`
Expected: FAIL — decoder defaults `llmEditEnabled` false / `update` doesn't persist the columns.

- [ ] **Step 3: Update `update(_:)`**

Replace the UPDATE in `SettingsStore.update`:

```swift
    public func update(_ profile: Profile) throws {
        let updated = Date()
        try database.write { db in
            try db.execute(sql: """
                UPDATE profile SET name=?, language=?, model_id=?, initial_prompt=?,
                                   llm_edit_enabled=?, llm_edit_prompt=?, updated_at=?
                WHERE id=?
            """, arguments: [profile.name, profile.language, profile.modelID,
                             profile.initialPrompt,
                             profile.llmEditEnabled ? 1 : 0, profile.llmEditPrompt,
                             Int64(updated.timeIntervalSince1970 * 1000),
                             profile.id])
        }
    }
```

- [ ] **Step 4: Update the `Profile(row:db:)` decoder**

In the `extension Profile`, read the new columns in `init(row:db:)`:

```swift
        self.init(
            id: id,
            name: row["name"], language: row["language"], modelID: row["model_id"],
            initialPrompt: row["initial_prompt"], vocab: vocab, rules: rules,
            llmEditEnabled: (row["llm_edit_enabled"] as Int) == 1,
            llmEditPrompt: row["llm_edit_prompt"],
            createdAt: date(row["created_at"]),
            updatedAt: date(row["updated_at"]),
            deletedAt: (row["deleted_at"] as Int64?).map(date)
        )
```

(`create(...)` needs no change — new rows take the column DEFAULT 0 / NULL, and the returned `Profile` uses the init defaults `false`/`nil`, which match.)

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path MumblurCore --filter SettingsStoreTests/testUpdate_roundTripsLLMEditFields`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add MumblurCore/Sources/MumblurCore/Storage/SettingsStore.swift \
        MumblurCore/Tests/MumblurCoreTests/Storage/SettingsStoreTests.swift
git commit -m "feat(storage): persist profile LLM-edit fields through SettingsStore"
```

### Task A4: Global LLMServerConfig in app_setting

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/LLMEditor.swift` (start the file with the two config value types)
- Modify: `MumblurCore/Sources/MumblurCore/Storage/SettingsStore.swift` (add accessors)
- Test: `MumblurCore/Tests/MumblurCoreTests/Storage/SettingsStoreTests.swift`

- [ ] **Step 1: Create the config value types**

```swift
// LLMEditor.swift
import Foundation
import os

public struct LLMServerConfig: Equatable, Sendable {
    public var enabled: Bool
    public var baseURL: String
    public var model: String
    public var timeoutMs: Int

    public init(enabled: Bool = false,
                baseURL: String = "http://localhost:8080",
                model: String = "",
                timeoutMs: Int = 5000) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.model = model
        self.timeoutMs = LLMServerConfig.clampTimeout(timeoutMs)
    }

    public static let `default` = LLMServerConfig()

    /// Clamp to a sane window; callers pass possibly-garbage stored values.
    public static func clampTimeout(_ ms: Int) -> Int { min(max(ms, 500), 60_000) }
}

public struct LLMEditConfig: Equatable, Sendable {
    public static let defaultPrompt =
        "Fix punctuation, capitalization, and remove filler words. " +
        "Do not change meaning or add content. Return only the corrected text."
    public static let disabled = LLMEditConfig(enabled: false, prompt: "")

    public let enabled: Bool
    public let prompt: String
    public init(enabled: Bool, prompt: String) {
        self.enabled = enabled
        self.prompt = prompt
    }
}
```

- [ ] **Step 2: Write the failing test**

Add to `SettingsStoreTests`:

```swift
func testLLMServerConfig_roundTrips_andClampsTimeout() async throws {
    let db = try AppDatabase(location: .inMemory)
    let store = SettingsStore(database: db)
    XCTAssertEqual(try await store.llmServerConfig(), .default)  // unset → default
    try await store.setLLMServerConfig(
        LLMServerConfig(enabled: true, baseURL: "http://x:1", model: "q", timeoutMs: 999_999))
    let back = try await store.llmServerConfig()
    XCTAssertEqual(back.enabled, true)
    XCTAssertEqual(back.baseURL, "http://x:1")
    XCTAssertEqual(back.model, "q")
    XCTAssertEqual(back.timeoutMs, 60_000)   // clamped
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --package-path MumblurCore --filter SettingsStoreTests/testLLMServerConfig_roundTrips_andClampsTimeout`
Expected: FAIL — `llmServerConfig` / `setLLMServerConfig` not defined.

- [ ] **Step 4: Add the accessors to `SettingsStore`**

```swift
    public func llmServerConfig() throws -> LLMServerConfig {
        try database.read { db in
            func str(_ k: String) -> String? {
                try? String.fetchOne(db, sql: "SELECT value FROM app_setting WHERE key=?",
                                     arguments: [k])
            }
            var cfg = LLMServerConfig.default
            if let v = str("llm.enabled")    { cfg.enabled = (v == "1") }
            if let v = str("llm.base_url"), !v.isEmpty { cfg.baseURL = v }
            if let v = str("llm.model")      { cfg.model = v }
            if let v = str("llm.timeout_ms"), let n = Int(v) {
                cfg.timeoutMs = LLMServerConfig.clampTimeout(n)
            }
            return cfg
        }
    }

    public func setLLMServerConfig(_ cfg: LLMServerConfig) throws {
        try database.write { db in
            func put(_ k: String, _ v: String) throws {
                try db.execute(sql: """
                    INSERT INTO app_setting(key,value) VALUES(?,?)
                    ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """, arguments: [k, v])
            }
            try put("llm.enabled", cfg.enabled ? "1" : "0")
            try put("llm.base_url", cfg.baseURL)
            try put("llm.model", cfg.model)
            try put("llm.timeout_ms", String(LLMServerConfig.clampTimeout(cfg.timeoutMs)))
        }
    }
```

Note: `try?` inside a throwing `read` closure is intentional — a missing key yields nil, not an error.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path MumblurCore --filter SettingsStoreTests/testLLMServerConfig_roundTrips_andClampsTimeout`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add MumblurCore/Sources/MumblurCore/LLMEditor.swift \
        MumblurCore/Sources/MumblurCore/Storage/SettingsStore.swift \
        MumblurCore/Tests/MumblurCoreTests/Storage/SettingsStoreTests.swift
git commit -m "feat(storage): LLMServerConfig persisted in app_setting"
```

---

## Phase B — Snapshot plumbing

### Task B1: ServingSnapshot gains llmEdit + copy helper

**Files:**
- Modify: `MumblurCore/Sources/MumblurCore/ServingSnapshot.swift`

- [ ] **Step 1: Add the field (defaulted) and a copy helper**

```swift
public struct ServingSnapshot: Equatable, Sendable {
    public let profileID: String
    public let profileName: String
    public let modelID: String
    public let language: String?
    public let prompt: PromptPayload
    public let rules: [ReplacementRule]
    public let llmEdit: LLMEditConfig

    public init(profileID: String, profileName: String, modelID: String,
                language: String?, prompt: PromptPayload, rules: [ReplacementRule],
                llmEdit: LLMEditConfig = .disabled) {
        self.profileID = profileID; self.profileName = profileName
        self.modelID = modelID; self.language = language
        self.prompt = prompt; self.rules = rules
        self.llmEdit = llmEdit
    }

    /// Copy with a replaced `llmEdit` — used by `Transcriber.updateLLMEdit` to
    /// patch active-profile AI settings without a model reload.
    public func with(llmEdit: LLMEditConfig) -> ServingSnapshot {
        ServingSnapshot(profileID: profileID, profileName: profileName, modelID: modelID,
                        language: language, prompt: prompt, rules: rules, llmEdit: llmEdit)
    }
}
```

- [ ] **Step 2: Build to confirm existing snapshot call sites still compile**

Run: `swift build --package-path MumblurCore`
Expected: builds clean (the `llmEdit` param is defaulted; `makeTranscriber` test helper and `ModelManager` still compile).

- [ ] **Step 3: Commit**

```bash
git add MumblurCore/Sources/MumblurCore/ServingSnapshot.swift
git commit -m "feat(core): ServingSnapshot carries LLMEditConfig + with(llmEdit:) copy"
```

### Task B2: ModelManager resolves llmEdit from the profile

**Files:**
- Modify: `MumblurCore/Sources/MumblurCore/ModelManager.swift:49-52`
- Test: `MumblurCore/Tests/MumblurCoreTests/ModelManagerTests.swift` (existing file — add a test; if absent, create it)

- [ ] **Step 1: Write the failing test**

If `ModelManagerTests.swift` does not exist, create it with this content; otherwise add the test method. A minimal fake loader is included so the test is self-contained:

```swift
import XCTest
@testable import MumblurCore

private struct FakeTokenizer: Tokenizing { func encode(text: String) throws -> [Int] { [] } }
private struct FakeKit: WhisperKitTranscribing {
    func transcribe(audioArray: [Float], language: String?, detectLanguage: Bool,
                    promptTokens: [Int]?) async throws -> [any WhisperKitSegment] { [] }
}
private struct FakeLoader: ModelLoading {
    func load(modelID: String) async throws -> LoadedModel {
        LoadedModel(kit: FakeKit(), tokenizer: FakeTokenizer())
    }
}

final class ModelManagerLLMEditTests: XCTestCase {
    private func profile(enabled: Bool, prompt: String?) -> Profile {
        Profile(id: "p", name: "P", language: nil, modelID: "m",
                initialPrompt: nil, vocab: [], rules: [],
                llmEditEnabled: enabled, llmEditPrompt: prompt,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0), deletedAt: nil)
    }

    func testSnapshot_resolvesEnabledAndDefaultPrompt() async throws {
        let mgr = ModelManager(loader: FakeLoader(), transcriber: Transcriber())
        let snapNilPrompt = try await mgr.requestSwap(to: profile(enabled: true, prompt: nil))
        XCTAssertTrue(snapNilPrompt.llmEdit.enabled)
        XCTAssertEqual(snapNilPrompt.llmEdit.prompt, LLMEditConfig.defaultPrompt)

        let snapBlank = try await mgr.requestSwap(to: profile(enabled: true, prompt: "   "))
        XCTAssertEqual(snapBlank.llmEdit.prompt, LLMEditConfig.defaultPrompt)

        let snapCustom = try await mgr.requestSwap(to: profile(enabled: true, prompt: "Custom"))
        XCTAssertEqual(snapCustom.llmEdit.prompt, "Custom")

        let snapOff = try await mgr.requestSwap(to: profile(enabled: false, prompt: "x"))
        XCTAssertFalse(snapOff.llmEdit.enabled)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MumblurCore --filter ModelManagerLLMEditTests`
Expected: FAIL — `snapshot.llmEdit` is `.disabled` (ModelManager doesn't populate it yet).

- [ ] **Step 3: Resolve llmEdit in `requestSwap`**

Replace the snapshot construction in `ModelManager.requestSwap`:

```swift
        let trimmedPrompt = profile.llmEditPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let editPrompt = (trimmedPrompt?.isEmpty ?? true) ? LLMEditConfig.defaultPrompt : trimmedPrompt!
        let llmEdit = LLMEditConfig(enabled: profile.llmEditEnabled, prompt: editPrompt)
        let snap = ServingSnapshot(
            profileID: profile.id, profileName: profile.name,
            modelID: profile.modelID, language: profile.language,
            prompt: payload, rules: profile.rules, llmEdit: llmEdit)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path MumblurCore --filter ModelManagerLLMEditTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MumblurCore/Sources/MumblurCore/ModelManager.swift \
        MumblurCore/Tests/MumblurCoreTests/ModelManagerTests.swift
git commit -m "feat(core): resolve per-profile LLMEditConfig into ServingSnapshot"
```

### Task B3: Transcriber.updateLLMEdit lightweight patch

**Files:**
- Modify: `MumblurCore/Sources/MumblurCore/Transcriber.swift`
- Test: `MumblurCore/Tests/MumblurCoreTests/TranscriberTests.swift` (existing — add a test; if absent, create it)

- [ ] **Step 1: Write the failing test**

```swift
func testUpdateLLMEdit_patchesServingSnapshot() async throws {
    let t = Transcriber()
    await t.commit(
        snapshot: ServingSnapshot(profileID: "p", profileName: "P", modelID: "m",
                                  language: nil, prompt: .empty, rules: [],
                                  llmEdit: .disabled),
        kit: FixedKit(text: "hi"))           // FixedKit available in this test target
    await t.updateLLMEdit(LLMEditConfig(enabled: true, prompt: "Polish"))
    let out = try await t.transcribe([0.5])
    XCTAssertTrue(out.snapshot.llmEdit.enabled)
    XCTAssertEqual(out.snapshot.llmEdit.prompt, "Polish")
}
```

If `FixedKit` is not visible in this file/target, inline a one-segment fake kit struct in the test.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MumblurCore --filter TranscriberTests/testUpdateLLMEdit_patchesServingSnapshot`
Expected: FAIL — `updateLLMEdit` not defined.

- [ ] **Step 3: Add the method to the `Transcriber` actor**

```swift
    /// Patch only the LLM-edit config of the active snapshot, leaving the loaded
    /// kit untouched. No-op if nothing is serving yet.
    public func updateLLMEdit(_ cfg: LLMEditConfig) {
        guard let snap = serving else { return }
        self.serving = snap.with(llmEdit: cfg)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path MumblurCore --filter TranscriberTests/testUpdateLLMEdit_patchesServingSnapshot`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MumblurCore/Sources/MumblurCore/Transcriber.swift \
        MumblurCore/Tests/MumblurCoreTests/TranscriberTests.swift
git commit -m "feat(core): Transcriber.updateLLMEdit patches snapshot without reload"
```

---

## Phase C — Protocol seam & Runner integration

### Task C1: TranscriptEditing protocol + NoOpEditor

**Files:**
- Modify: `MumblurCore/Sources/MumblurCore/LLMEditor.swift`

- [ ] **Step 1: Append the protocol and the no-op default**

```swift
public protocol TranscriptEditing: Sendable {
    /// Best-effort cleanup. Returns `text` unchanged on any network/timeout/
    /// parse failure, when globally disabled, or when unconfigured. Propagates
    /// `CancellationError` so a cancelled worker never proceeds to paste.
    func editFailOpen(_ text: String, instructions: String) async throws -> String
}

/// Default seam: identity. Used as the `Runner.init` default so existing call
/// sites (incl. ~10 test sites) keep compiling, and as the production default
/// until the real editor is injected.
public struct NoOpEditor: TranscriptEditing {
    public init() {}
    public func editFailOpen(_ text: String, instructions: String) async throws -> String { text }
}
```

- [ ] **Step 2: Build**

Run: `swift build --package-path MumblurCore`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add MumblurCore/Sources/MumblurCore/LLMEditor.swift
git commit -m "feat(core): TranscriptEditing protocol + NoOpEditor"
```

### Task C2: Wire the editor seam into Runner

**Files:**
- Modify: `MumblurCore/Sources/MumblurCore/Runner.swift:25-42` (init/stored props) and `:150-178` (doWork)

- [ ] **Step 1: Add the defaulted init parameter and stored property**

In `Runner.init`, add `editor` after `persister` with a `NoOpEditor()` default, and store it:

```swift
    public init(
        recorder: AudioRecording,
        transcriber: Transcriber,
        paster: Pasting,
        persister: any DictationPersisting,
        editor: any TranscriptEditing = NoOpEditor(),
        minHoldMs: Int = 200,
        clock: @escaping @Sendable () -> Date = { Date() },
        onStateChange: @escaping @Sendable (State) -> Void = { _ in }
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.paster = paster
        self.persister = persister
        self.editor = editor
        self.minHoldMs = minHoldMs
        self.clock = clock
        self.onStateChange = onStateChange
        self.lock = OSAllocatedUnfairLock(initialState: MutableState())
    }
```

Add the stored property near the other lets (after `persister`):

```swift
    private let editor: any TranscriptEditing
```

- [ ] **Step 2: Insert the LLM stage in `doWork`**

Replace the body of the `do { ... }` in `doWork` (currently Runner.swift:158-172) with:

```swift
        do {
            let output = try await transcriber.transcribe(samples)
            guard !Task.isCancelled else { return }
            var text = output.rawText
            if output.snapshot.llmEdit.enabled {
                text = try await editor.editFailOpen(text, instructions: output.snapshot.llmEdit.prompt)
                guard !Task.isCancelled else { return }   // do not paste a cancelled run
            }
            let finalText = postProcessor.apply(text, rules: output.snapshot.rules)
            guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await paster.paste(finalText)
            await persister.persist(
                samples: samples,
                snapshot: output.snapshot,
                startedAt: startedAt,
                durationMs: durationMs,
                rawText: output.rawText,
                finalText: finalText)
        } catch is CancellationError {
            Logger.runner.debug("worker cancelled")
        } catch {
            Logger.transcribe.error("transcribe failed: \(error.localizedDescription)")
        }
```

(The `editFailOpen` call sits inside the existing `do`; a thrown `CancellationError` lands in the existing `catch is CancellationError` and skips paste. Network/timeout errors are already swallowed inside `editFailOpen`, so they never reach here.)

- [ ] **Step 3: Build to confirm existing Runner call sites still compile**

Run: `swift build --package-path MumblurCore`
Expected: builds clean (the `editor` param is defaulted, so the ~10 existing `Runner(...)` sites are unaffected).

- [ ] **Step 4: Run the existing Runner suites to confirm no regression**

Run: `swift test --package-path MumblurCore --filter RunnerTests`
Then: `swift test --package-path MumblurCore --filter RunnerPostProcessTests`
Expected: PASS (NoOpEditor is identity; `llmEdit.enabled` defaults false in those snapshots, so the stage is skipped).

- [ ] **Step 5: Commit**

```bash
git add MumblurCore/Sources/MumblurCore/Runner.swift
git commit -m "feat(core): Runner LLM-edit stage before rules, with cancellation guard"
```

### Task C3: Runner LLM-stage behavior tests

**Files:**
- Modify: `MumblurCore/Tests/MumblurCoreTests/RunnerTests.swift`

- [ ] **Step 1: Add fakes + tests**

Add near the other private fakes (after `NoOpPersister`):

```swift
/// Returns a fixed edited string (models a successful LLM edit).
private struct StubEditor: TranscriptEditing {
    let edited: String
    func editFailOpen(_ text: String, instructions: String) async throws -> String { edited }
}
/// Returns input unchanged (models a swallowed network/timeout failure — fail-open).
private struct PassthroughEditor: TranscriptEditing {
    func editFailOpen(_ text: String, instructions: String) async throws -> String { text }
}
/// Throws CancellationError (models worker cancellation mid-edit).
private struct CancellingEditor: TranscriptEditing {
    func editFailOpen(_ text: String, instructions: String) async throws -> String {
        throw CancellationError()
    }
}
/// Records whether it was ever invoked.
private actor RecordingEditor: TranscriptEditing {
    private(set) var calls = 0
    func editFailOpen(_ text: String, instructions: String) async throws -> String {
        calls += 1; return text
    }
    func callCount() -> Int { calls }
}

private func makeTranscriberWithEdit(_ kit: any WhisperKitTranscribing,
                                     enabled: Bool, prompt: String = "p",
                                     rules: [ReplacementRule] = []) async -> Transcriber {
    let t = Transcriber()
    await t.commit(
        snapshot: ServingSnapshot(profileID: "t", profileName: "T", modelID: "m",
                                  language: nil, prompt: .empty, rules: rules,
                                  llmEdit: LLMEditConfig(enabled: enabled, prompt: prompt)),
        kit: kit)
    return t
}
```

Add a new test suite:

```swift
final class RunnerLLMEditTests: XCTestCase {
    private func rule(_ p: String, _ r: String) -> ReplacementRule {
        ReplacementRule(id: 0, profileID: "t", pattern: p, replacement: r,
                        isRegex: false, caseSensitive: false, wordBoundary: true, sortOrder: 0)
    }

    func testEnabled_editedTextReachesPaste() async throws {
        let rec = FakeAudioRecorder()
        let tr = await makeTranscriberWithEdit(FixedKit(text: "raw words"), enabled: true)
        let paster = SpyPaster()
        let runner = Runner(recorder: rec, transcriber: tr, paster: paster,
                            persister: NoOpPersister(), editor: StubEditor(edited: "edited words"),
                            minHoldMs: 0)
        runner.onPress(); rec.push([0.5]); runner.onRelease()
        await waitUntilIdle(runner)
        let pasted = await paster.getCalls()
        XCTAssertEqual(pasted, ["edited words"])
    }

    func testEnabled_failOpenPassthrough_stillPastes() async throws {
        let rec = FakeAudioRecorder()
        let tr = await makeTranscriberWithEdit(FixedKit(text: "hello"), enabled: true)
        let paster = SpyPaster()
        let runner = Runner(recorder: rec, transcriber: tr, paster: paster,
                            persister: NoOpPersister(), editor: PassthroughEditor(), minHoldMs: 0)
        runner.onPress(); rec.push([0.5]); runner.onRelease()
        await waitUntilIdle(runner)
        let pasted = await paster.getCalls()
        XCTAssertEqual(pasted, ["hello"])
    }

    func testEnabled_cancellation_doesNotPaste() async throws {
        let rec = FakeAudioRecorder()
        let tr = await makeTranscriberWithEdit(FixedKit(text: "hello"), enabled: true)
        let paster = SpyPaster()
        let runner = Runner(recorder: rec, transcriber: tr, paster: paster,
                            persister: NoOpPersister(), editor: CancellingEditor(), minHoldMs: 0)
        runner.onPress(); rec.push([0.5]); runner.onRelease()
        await waitUntilIdle(runner)
        let pasted = await paster.getCalls()
        XCTAssertEqual(pasted, [])   // CancellationError → no paste
    }

    func testDisabled_editorNeverCalled() async throws {
        let rec = FakeAudioRecorder()
        let tr = await makeTranscriberWithEdit(FixedKit(text: "hello"), enabled: false)
        let paster = SpyPaster()
        let editor = RecordingEditor()
        let runner = Runner(recorder: rec, transcriber: tr, paster: paster,
                            persister: NoOpPersister(), editor: editor, minHoldMs: 0)
        runner.onPress(); rec.push([0.5]); runner.onRelease()
        await waitUntilIdle(runner)
        let count = await editor.callCount()
        XCTAssertEqual(count, 0)
        let pasted = await paster.getCalls()
        XCTAssertEqual(pasted, ["hello"])
    }

    func testRulesRunAfterLLM_ruleWins() async throws {
        let rec = FakeAudioRecorder()
        // LLM outputs "Quest"; a rule rewrites Quest→Questable AFTER the LLM.
        let tr = await makeTranscriberWithEdit(FixedKit(text: "x"), enabled: true,
                                               rules: [rule("Quest", "Questable")])
        let paster = SpyPaster()
        let runner = Runner(recorder: rec, transcriber: tr, paster: paster,
                            persister: NoOpPersister(), editor: StubEditor(edited: "Quest rocks"),
                            minHoldMs: 0)
        runner.onPress(); rec.push([0.5]); runner.onRelease()
        await waitUntilIdle(runner)
        let pasted = await paster.getCalls()
        XCTAssertEqual(pasted, ["Questable rocks"])   // rule applied to LLM output
    }
}
```

- [ ] **Step 2: Run the new suite**

Run: `swift test --package-path MumblurCore --filter RunnerLLMEditTests`
Expected: PASS (all five).

- [ ] **Step 3: Commit**

```bash
git add MumblurCore/Tests/MumblurCoreTests/RunnerTests.swift
git commit -m "test(core): Runner LLM-edit ordering, fail-open, cancellation, gating"
```

---

## Phase D — OpenAICompatibleEditor (real HTTP)

### Task D1: URL normalization helper

**Files:**
- Modify: `MumblurCore/Sources/MumblurCore/LLMEditor.swift`
- Test: `MumblurCore/Tests/MumblurCoreTests/LLMEditorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// LLMEditorTests.swift
import XCTest
@testable import MumblurCore

final class LLMEditorURLTests: XCTestCase {
    func testEndpoint_normalizesBase() {
        XCTAssertEqual(OpenAICompatibleEditor.endpoint(base: "http://localhost:8080")?.absoluteString,
                       "http://localhost:8080/v1/chat/completions")
        XCTAssertEqual(OpenAICompatibleEditor.endpoint(base: "http://localhost:8080/")?.absoluteString,
                       "http://localhost:8080/v1/chat/completions")
        XCTAssertEqual(OpenAICompatibleEditor.endpoint(base: "http://localhost:8080/v1")?.absoluteString,
                       "http://localhost:8080/v1/chat/completions")
        XCTAssertNil(OpenAICompatibleEditor.endpoint(base: ""))
        XCTAssertNil(OpenAICompatibleEditor.endpoint(base: "   "))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MumblurCore --filter LLMEditorURLTests`
Expected: FAIL — `OpenAICompatibleEditor` not defined.

- [ ] **Step 3: Add the editor skeleton + endpoint normalizer**

Append to `LLMEditor.swift`:

```swift
public actor OpenAICompatibleEditor: TranscriptEditing {
    private var config: LLMServerConfig
    private let session: URLSession

    public init(config: LLMServerConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = Double(config.timeoutMs) / 1000.0
            self.session = URLSession(configuration: c)
        }
    }

    public func configure(_ config: LLMServerConfig) { self.config = config }

    /// Normalize a user-entered base URL into the chat-completions endpoint.
    /// Accepts `http://host:port`, a trailing `/`, or a trailing `/v1`.
    static func endpoint(base: String) -> URL? {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1") { s.removeLast(3) }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + "/v1/chat/completions")
    }

    public func editFailOpen(_ text: String, instructions: String) async throws -> String {
        // Implemented in Task D2.
        return text
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path MumblurCore --filter LLMEditorURLTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MumblurCore/Sources/MumblurCore/LLMEditor.swift \
        MumblurCore/Tests/MumblurCoreTests/LLMEditorTests.swift
git commit -m "feat(core): OpenAICompatibleEditor skeleton + URL normalization"
```

### Task D2: Request/response, fail-open, hard timeout

**Files:**
- Modify: `MumblurCore/Sources/MumblurCore/LLMEditor.swift`
- Test: `MumblurCore/Tests/MumblurCoreTests/LLMEditorTests.swift`

- [ ] **Step 1: Write the failing tests (URLProtocol stub)**

Add to `LLMEditorTests.swift`:

```swift
/// Drives URLSession deterministically. `handler` returns (status, body) or
/// sleeps to model a stall; honors task cancellation via `stopLoading`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var stallSeconds: Double = 0
    private var cancelled = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        if Self.stallSeconds > 0 {
            // Cooperative stall: poll the cancel flag so stopLoading() ends it.
            let deadline = Date().addingTimeInterval(Self.stallSeconds)
            while Date() < deadline && !cancelled { Thread.sleep(forTimeInterval: 0.01) }
            if cancelled { return }
        }
        let (status, body) = Self.handler?(request) ?? (200, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { cancelled = true }
}

private func stubSession() -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: c)
}

private func chatBody(_ content: String) -> Data {
    Data(#"{"choices":[{"message":{"role":"assistant","content":"\#(content)"}}]}"#.utf8)
}

final class LLMEditorBehaviorTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.stallSeconds = 0
        super.tearDown()
    }

    func testSuccess_returnsEditedContent() async throws {
        StubURLProtocol.handler = { _ in (200, chatBody("cleaned text")) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, baseURL: "http://localhost:8080",
                                    model: "q", timeoutMs: 5000),
            session: stubSession())
        let out = try await ed.editFailOpen("raw text", instructions: "fix it")
        XCTAssertEqual(out, "cleaned text")
    }

    func testGloballyDisabled_returnsInput_noRequest() async throws {
        var hit = false
        StubURLProtocol.handler = { _ in hit = true; return (200, chatBody("x")) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: false, baseURL: "http://localhost:8080",
                                    model: "q", timeoutMs: 5000),
            session: stubSession())
        let out = try await ed.editFailOpen("raw", instructions: "fix")
        XCTAssertEqual(out, "raw")
        XCTAssertFalse(hit)   // kill-switch: no HTTP issued
    }

    func testNon2xx_failsOpen() async throws {
        StubURLProtocol.handler = { _ in (500, Data("oops".utf8)) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, model: "q", timeoutMs: 5000),
            session: stubSession())
        let out = try await ed.editFailOpen("raw", instructions: "fix")
        XCTAssertEqual(out, "raw")
    }

    func testMalformedJSON_failsOpen() async throws {
        StubURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, model: "q", timeoutMs: 5000),
            session: stubSession())
        let out = try await ed.editFailOpen("raw", instructions: "fix")
        XCTAssertEqual(out, "raw")
    }

    func testEmptyCompletion_failsOpenToInput() async throws {
        StubURLProtocol.handler = { _ in (200, chatBody("   ")) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, model: "q", timeoutMs: 5000),
            session: stubSession())
        let out = try await ed.editFailOpen("raw", instructions: "fix")
        XCTAssertEqual(out, "raw")
    }

    func testTimeout_failsOpen_withinBudget() async throws {
        StubURLProtocol.stallSeconds = 5.0          // server stalls well past timeout
        StubURLProtocol.handler = { _ in (200, chatBody("late")) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, model: "q", timeoutMs: 300),
            session: stubSession())
        let start = Date()
        let out = try await ed.editFailOpen("raw", instructions: "fix")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(out, "raw")
        XCTAssertLessThan(elapsed, 2.0)             // hard timeout, not the 5s stall
    }

    func testRequestBody_hasSystemAndUserMessages() async throws {
        nonisolated(unsafe) var captured: Data?
        StubURLProtocol.handler = { req in
            captured = req.httpBodyStreamData() ?? req.httpBody
            return (200, chatBody("ok"))
        }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, model: "mymodel", timeoutMs: 5000),
            session: stubSession())
        _ = try await ed.editFailOpen("hello", instructions: "be terse")
        let json = try XCTUnwrap(captured).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let messages = json?["messages"] as? [[String: String]]
        XCTAssertEqual(json?["model"] as? String, "mymodel")
        XCTAssertEqual(messages?.first?["role"], "system")
        XCTAssertEqual(messages?.first?["content"], "be terse")
        XCTAssertEqual(messages?.last?["role"], "user")
        XCTAssertEqual(messages?.last?["content"], "hello")
    }
}

// URLProtocol can receive the body as a stream; read it for assertions.
private extension URLRequest {
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); let size = 4096; var buf = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: size)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path MumblurCore --filter LLMEditorBehaviorTests`
Expected: FAIL — `editFailOpen` currently returns input for all cases (success/body/timeout assertions fail).

- [ ] **Step 3: Implement `editFailOpen` + request/response + timeout race**

Replace the placeholder `editFailOpen` and add the supporting code in `OpenAICompatibleEditor`:

```swift
    private struct TimeoutError: Error {}

    private struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let stream: Bool
    }
    private struct ChatResponse: Decodable {
        struct Choice: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }
        let choices: [Choice]
    }

    public func editFailOpen(_ text: String, instructions: String) async throws -> String {
        let cfg = config
        guard cfg.enabled, let url = Self.endpoint(base: cfg.baseURL) else { return text }
        let model = cfg.model
        let session = self.session
        do {
            let edited = try await Self.race(timeoutMs: cfg.timeoutMs) {
                try await Self.perform(session: session, url: url, model: model,
                                       system: instructions, user: text)
            }
            let trimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? text : trimmed
        } catch is CancellationError {
            throw CancellationError()                 // external cancel → propagate
        } catch {
            Logger.transcribe.info("LLM edit failed open: \(error.localizedDescription, privacy: .public)")
            return text
        }
    }

    private static func perform(session: URLSession, url: URL, model: String,
                                system: String, user: String) async throws -> String {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ChatRequest(model: model,
                               messages: [.init(role: "system", content: system),
                                          .init(role: "user", content: user)],
                               stream: false)
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw URLError(.cannotParseResponse)
        }
        return content
    }

    /// First-result race between the operation and a sleep. The sleep winning
    /// throws TimeoutError (→ fail-open). `defer { cancelAll() }` ensures the
    /// loser is cancelled; `session.data(for:)` is cancellation-cooperative so
    /// the wall-clock cap is hard. External cancellation propagates as
    /// CancellationError.
    private static func race(timeoutMs: Int,
                             _ op: @escaping @Sendable () async throws -> String) async throws -> String {
        try await withThrowingTaskGroup(of: String?.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                return nil   // timeout sentinel
            }
            while let result = try await group.next() {
                if let value = result { return value }  // op finished first
                throw TimeoutError()                    // sleep finished first
            }
            throw TimeoutError()
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path MumblurCore --filter LLMEditorBehaviorTests`
Expected: PASS (all). If the timeout test flakes on a loaded CI box, the assertion bound (`< 2.0` for a 300ms timeout) has ample margin; investigate the race/`cancelAll` wiring before loosening it.

- [ ] **Step 5: Run the whole core test suite**

Run: `swift test --package-path MumblurCore`
Expected: PASS — no regressions.

- [ ] **Step 6: Commit**

```bash
git add MumblurCore/Sources/MumblurCore/LLMEditor.swift \
        MumblurCore/Tests/MumblurCoreTests/LLMEditorTests.swift
git commit -m "feat(core): OpenAICompatibleEditor HTTP, fail-open, hard timeout race"
```

---

## Phase E — App wiring (AppCoordinator)

### Task E1: Construct and inject the editor in bootstrap

**Files:**
- Modify: `App/AppCoordinator.swift` (bootstrap ~143-178; add a stored property near the other seam properties)

- [ ] **Step 1: Add a stored property for the editor**

Near the other private stores/seams in `AppCoordinator` (e.g. beside `var transcriber: Transcriber?`), add:

```swift
    private var llmEditor: OpenAICompatibleEditor?
```

- [ ] **Step 2: Build the editor from stored config and inject it into Runner**

In `bootstrap()`, after `let persister = RetentionAwarePersister(...)` (line ~146) and before `Runner(...)` (line ~167), construct the editor; then pass it to `Runner`:

```swift
            let llmConfig = try await settings.llmServerConfig()
            let editor = OpenAICompatibleEditor(config: llmConfig)

            // ... existing recorder / paster lines ...
            let runner = Runner(
                recorder: recorder, transcriber: transcriber,
                paster: paster, persister: persister, editor: editor, minHoldMs: 200,
                onStateChange: { [weak self] s in
                    Task { @MainActor in self?.applyRunnerState(s) }
                })
```

Then store it alongside the other assignments (line ~177):

```swift
            self.llmEditor = editor
```

- [ ] **Step 3: Build the app**

Delegate to the apple-platform-build-tools builder agent: "Build the Mumblur macOS app scheme and report only success or the first compile error."
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add App/AppCoordinator.swift
git commit -m "feat(app): construct + inject OpenAICompatibleEditor in bootstrap"
```

### Task E2: setLLMServerConfig and updateProfileAISettings

**Files:**
- Modify: `App/AppCoordinator.swift` (add two methods near `switchActiveProfile` / `setActiveProfileModel`, ~234-264)

- [ ] **Step 1: Add the global-config setter**

```swift
    /// Persist global LLM server config and hot-swap it into the live editor so
    /// URL/model/timeout/enable changes take effect immediately.
    func setLLMServerConfig(_ cfg: LLMServerConfig) async {
        guard let settings = settingsStore else { return }
        do {
            try await settings.setLLMServerConfig(cfg)
            await llmEditor?.configure(cfg)
        } catch {
            Logger.app.error("setLLMServerConfig failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    func currentLLMServerConfig() async -> LLMServerConfig {
        guard let settings = settingsStore else { return .default }
        return (try? await settings.llmServerConfig()) ?? .default
    }
```

- [ ] **Step 2: Add the per-profile setter with active-profile snapshot patch**

```swift
    /// Persist a profile's LLM-edit settings. If it is the active profile, patch
    /// the live serving snapshot in place (no model reload).
    func updateProfileAISettings(profileID: String, enabled: Bool, prompt: String?) async {
        guard let settings = settingsStore,
              var profile = try? await settings.get(profileID: profileID) else { return }
        profile.llmEditEnabled = enabled
        profile.llmEditPrompt = prompt
        do {
            try await settings.update(profile)
            settingsBridge.profiles = try await settings.listActive()
            if settingsBridge.activeProfileID == profileID {
                let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = (trimmed?.isEmpty ?? true) ? LLMEditConfig.defaultPrompt : trimmed!
                await transcriber?.updateLLMEdit(
                    LLMEditConfig(enabled: enabled, prompt: resolved))
            }
        } catch {
            Logger.app.error("updateProfileAISettings failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }
```

- [ ] **Step 3: Build the app**

Delegate to the builder agent: "Build the Mumblur macOS app scheme; report success or first error."
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add App/AppCoordinator.swift
git commit -m "feat(app): coordinator setters for global + per-profile LLM settings"
```

---

## Phase F — Settings UI (AI Editing tab)

### Task F1: AIViewModel

**Files:**
- Create: `App/Settings/ViewModels/AIViewModel.swift`

- [ ] **Step 1: Create the view model with a Deps seam (mirrors DataViewModel)**

```swift
// App/Settings/ViewModels/AIViewModel.swift
import SwiftUI
import MumblurCore

@MainActor
final class AIViewModel: ObservableObject {
    struct Deps {
        let loadConfig: @MainActor () async -> LLMServerConfig
        let saveConfig: @MainActor (_ cfg: LLMServerConfig) async -> Void
        let loadProfiles: @MainActor () async -> [Profile]
        let activeProfileID: @MainActor () -> String?
        let saveProfileAI: @MainActor (_ id: String, _ enabled: Bool, _ prompt: String?) async -> Void
        let testConnection: @MainActor (_ cfg: LLMServerConfig) async -> String
    }

    @Published var enabled = false
    @Published var baseURL = "http://localhost:8080"
    @Published var model = ""
    @Published var timeoutMs = 5000
    @Published var profiles: [Profile] = []
    @Published var selectedProfileID: String?
    @Published var profileEditEnabled = false
    @Published var profilePrompt = ""
    @Published var testResult: String?

    private let deps: Deps
    init(deps: Deps) { self.deps = deps }

    func load() async {
        let cfg = await deps.loadConfig()
        enabled = cfg.enabled; baseURL = cfg.baseURL; model = cfg.model; timeoutMs = cfg.timeoutMs
        profiles = await deps.loadProfiles()
        selectedProfileID = selectedProfileID ?? deps.activeProfileID() ?? profiles.first?.id
        syncProfileFields()
    }

    func saveGlobal() async {
        await deps.saveConfig(LLMServerConfig(enabled: enabled, baseURL: baseURL,
                                              model: model, timeoutMs: timeoutMs))
    }

    func selectProfile(_ id: String?) { selectedProfileID = id; syncProfileFields() }

    func saveProfile() async {
        guard let id = selectedProfileID else { return }
        await deps.saveProfileAI(id, profileEditEnabled,
                                 profilePrompt.isEmpty ? nil : profilePrompt)
        profiles = await deps.loadProfiles()
    }

    func test() async {
        testResult = "Testing…"
        testResult = await deps.testConnection(
            LLMServerConfig(enabled: true, baseURL: baseURL, model: model, timeoutMs: timeoutMs))
    }

    private func syncProfileFields() {
        let p = profiles.first { $0.id == selectedProfileID }
        profileEditEnabled = p?.llmEditEnabled ?? false
        profilePrompt = p?.llmEditPrompt ?? ""
    }
}
```

- [ ] **Step 2: Build the app**

Delegate to the builder agent: "Build the Mumblur macOS app scheme; report success or first error."
Expected: builds clean (view not yet referenced; this confirms the VM compiles).

- [ ] **Step 3: Commit**

```bash
git add App/Settings/ViewModels/AIViewModel.swift
git commit -m "feat(ui): AIViewModel for the AI Editing settings tab"
```

### Task F2: AISettingsView + a live test-connection editor

**Files:**
- Create: `App/Settings/AISettingsView.swift`

- [ ] **Step 1: Create the view and its `.live` Deps factory**

```swift
// App/Settings/AISettingsView.swift
import SwiftUI
import MumblurCore

struct AISettingsView: View {
    let coordinator: AppCoordinator
    @StateObject private var vm: AIViewModel

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _vm = StateObject(wrappedValue: AIViewModel(deps: .live(coordinator)))
    }

    var body: some View {
        Form {
            Section("Local LLM Server") {
                Toggle("Enable LLM editing", isOn: $vm.enabled)
                TextField("Base URL", text: $vm.baseURL)
                TextField("Model", text: $vm.model)
                Stepper("Timeout: \(vm.timeoutMs) ms", value: $vm.timeoutMs,
                        in: 500...60_000, step: 500)
                HStack {
                    Button("Save") { Task { await vm.saveGlobal() } }
                    Button("Test connection") { Task { await vm.test() } }
                    if let r = vm.testResult { Text(r).foregroundStyle(.secondary) }
                }
            }
            Section("Per-Profile Editing") {
                Picker("Profile", selection: Binding(
                    get: { vm.selectedProfileID },
                    set: { vm.selectProfile($0) })) {
                    ForEach(vm.profiles) { p in Text(p.name).tag(Optional(p.id)) }
                }
                Toggle("Edit transcripts for this profile", isOn: $vm.profileEditEnabled)
                VStack(alignment: .leading) {
                    Text("Editing instructions").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $vm.profilePrompt).frame(minHeight: 80)
                        .font(.body.monospaced())
                }
                Button("Save profile") { Task { await vm.saveProfile() } }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await vm.load() }
    }
}

extension AIViewModel.Deps {
    @MainActor
    static func live(_ c: AppCoordinator) -> AIViewModel.Deps {
        AIViewModel.Deps(
            loadConfig: { await c.currentLLMServerConfig() },
            saveConfig: { await c.setLLMServerConfig($0) },
            loadProfiles: { (try? await c.settingsStore?.listActive()) ?? [] },
            activeProfileID: { c.settingsBridge.activeProfileID },
            saveProfileAI: { await c.updateProfileAISettings(profileID: $0, enabled: $1, prompt: $2) },
            testConnection: { cfg in
                let editor = OpenAICompatibleEditor(config: cfg)
                do {
                    let out = try await editor.editFailOpen("ping", instructions: "Reply with: ok")
                    return out == "ping" ? "No response (check server/model)" : "Connected ✓"
                } catch { return "Failed: \(error.localizedDescription)" }
            })
    }
}
```

Note: `editFailOpen` returns the input unchanged on failure, so `out == "ping"` means the server did not produce a usable completion; any other text means it responded. This satisfies the spec's "real minimal chat completion" requirement.

If `settingsStore` is `private` on `AppCoordinator`, add a `@MainActor` accessor method on the coordinator (e.g. `func listActiveProfiles() async -> [Profile]`) and call that instead of touching the store directly — match whatever access level the existing tabs use.

- [ ] **Step 2: Register the tab in SettingsScene**

In `App/Settings/SettingsScene.swift`, add the tab after `DataSettingsView` (line ~15):

```swift
            AISettingsView(coordinator: coordinator)
                .tabItem { Label("AI Editing", systemImage: "sparkles") }
```

- [ ] **Step 3: Build the app**

Delegate to the builder agent: "Build the Mumblur macOS app scheme; report success or first error."
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add App/Settings/AISettingsView.swift App/Settings/SettingsScene.swift
git commit -m "feat(ui): AI Editing settings tab (global server + per-profile)"
```

### Task F3: Manual verification

- [ ] **Step 1: Start the local LLM server**

Start llama.cpp's server (or Ollama) on `http://localhost:8080`. Confirm it answers:

```bash
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"x","messages":[{"role":"user","content":"say ok"}],"stream":false}' | head -c 400
```
Expected: a JSON object with `choices[0].message.content`.

- [ ] **Step 2: Run the app and verify the golden path**

Run the app (delegate launch to the builder agent or run the built product). Then:
1. Open Settings → AI Editing. Toggle "Enable LLM editing", set Base URL, set Model, Save.
2. Click "Test connection" → expect "Connected ✓".
3. Select the active profile, toggle "Edit transcripts for this profile" on, enter a prompt (or leave blank for the default), Save profile.
4. Dictate a messy phrase (e.g. "um so like the the meeting is at three"). Confirm the pasted text is cleaned up.
5. With editing enabled, stop the LLM server and dictate again → confirm dictation still works (raw/rule-processed text pastes within the timeout; no hang).
6. Turn the global master switch off → dictate → confirm no LLM call (text pastes immediately, unedited beyond rules).

- [ ] **Step 3: Confirm calibration is unaffected**

Run a calibration in Settings → Tuning with LLM editing enabled on the active profile. Confirm it completes and WER reflects Whisper+rules (editing is bypassed because calibration does not route through `Runner.doWork`).

- [ ] **Step 4: Final full core test run**

Run: `swift test --package-path MumblurCore`
Expected: PASS — entire suite green.

---

## Self-Review notes

- **Spec coverage:** protocol seam (C1), config split (A4/B1/B2), pipeline order + cancellation (C2/C3), fail-open + hard timeout (D2), two-gate kill-switch (D2 `testGloballyDisabled`), migration V2 (A2), SettingsStore three touch points (A3), serving refresh via `updateLLMEdit` (B3/E2), AppCoordinator wiring (E1/E2), AI tab + test-connection (F1/F2), calibration bypass verified (F3). All spec sections map to a task.
- **No-reload active-profile refresh** is implemented exactly as the revised spec requires (`Transcriber.updateLLMEdit`, not `requestSwap`).
- **Type consistency:** `editFailOpen(_:instructions:)`, `LLMEditConfig(enabled:prompt:)`, `LLMServerConfig(enabled:baseURL:model:timeoutMs:)`, `ServingSnapshot.with(llmEdit:)`, `OpenAICompatibleEditor.endpoint(base:)` / `.configure(_:)` are used identically across tasks.
- **Compatibility:** every new init parameter (`Runner.editor`, `Profile.llmEdit*`, `ServingSnapshot.llmEdit`) is defaulted so the ~10 existing `Runner(...)` test sites and existing snapshot/profile constructions keep compiling.
