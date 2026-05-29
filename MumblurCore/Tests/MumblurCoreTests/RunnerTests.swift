import XCTest
@testable import MumblurCore

// MARK: - Shared helpers

/// Builds a real Transcriber committed with a snapshot + the given kit.
private func makeTranscriber(_ kit: any WhisperKitTranscribing,
                             profileName: String = "T", modelID: String = "m",
                             rules: [ReplacementRule] = []) async -> Transcriber {
    let t = Transcriber()
    await t.commit(
        snapshot: ServingSnapshot(profileID: "t", profileName: profileName, modelID: modelID,
                                  language: nil, prompt: .empty, rules: rules),
        kit: kit)
    return t
}

private struct FixedKit: WhisperKitTranscribing {
    let text: String
    init(text: String = "hello") { self.text = text }
    func transcribe(audioArray: [Float], language: String?, detectLanguage: Bool,
                    promptTokens: [Int]?) async throws -> [any WhisperKitSegment] {
        struct S: WhisperKitSegment { let text: String }
        return [S(text: text)]
    }
}

private final class BlockingKit: WhisperKitTranscribing, @unchecked Sendable {
    let text: String
    private let unblockEvent = AsyncStream<Void>.makeStream()
    init(text: String) { self.text = text }
    func transcribe(audioArray: [Float], language: String?, detectLanguage: Bool,
                    promptTokens: [Int]?) async throws -> [any WhisperKitSegment] {
        var it = unblockEvent.stream.makeAsyncIterator()
        _ = await it.next()
        struct S: WhisperKitSegment { let text: String }
        return [S(text: text)]
    }
    func unblock() {
        unblockEvent.continuation.yield(())
        unblockEvent.continuation.finish()
    }
}

private final class ThrowingKit: WhisperKitTranscribing, @unchecked Sendable {
    struct Boom: Error {}
    func transcribe(audioArray: [Float], language: String?, detectLanguage: Bool,
                    promptTokens: [Int]?) async throws -> [any WhisperKitSegment] {
        throw Boom()
    }
}

private struct NoOpPersister: DictationPersisting {
    func persist(samples: [Float], snapshot: ServingSnapshot, startedAt: Date,
                 durationMs: Int, rawText: String, finalText: String) async {}
}

private actor SpyPersister: DictationPersisting {
    struct Insert: Sendable {
        let profileName: String
        let modelID: String
        let rawText: String
        let finalText: String
    }
    private(set) var inserts: [Insert] = []
    func persist(samples: [Float], snapshot: ServingSnapshot, startedAt: Date,
                 durationMs: Int, rawText: String, finalText: String) async {
        inserts.append(Insert(profileName: snapshot.profileName, modelID: snapshot.modelID,
                              rawText: rawText, finalText: finalText))
    }
    func getInserts() -> [Insert] { inserts }
}

private func waitUntilIdle(_ runner: Runner) async {
    for _ in 0..<200 {
        if runner.state == .idle { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("timed out waiting for runner to return to .idle")
}

private func waitForState(_ runner: Runner, _ target: Runner.State) async throws {
    for _ in 0..<200 {
        if runner.state == target { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw NSError(domain: "test", code: 0,
                  userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(target)"])
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: TimeInterval = 0
    var now: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); _now = newValue; lock.unlock() }
    }
    func date() -> Date { Date(timeIntervalSince1970: now) }
}

actor SpyPaster: Pasting {
    var calls: [String] = []
    func paste(_ text: String) async { calls.append(text) }
    func getCalls() -> [String] { calls }
}

final class SlowStopRecorder: AudioRecording, @unchecked Sendable {
    private let stopGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _active = false
    private var _startCount = 0
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return _startCount }
    func start() throws { lock.lock(); defer { lock.unlock() }; _active = true; _startCount += 1 }
    func stop() -> [Float] {
        stopGate.wait()
        lock.lock(); defer { lock.unlock() }
        _active = false
        return [0.0]
    }
    func abortIfActive() { lock.lock(); defer { lock.unlock() }; _active = false }
    func unblockStop() { stopGate.signal() }
}

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
/// Captures the instructions string the editor received (for few-shot assertions).
private actor CapturingEditor: TranscriptEditing {
    private(set) var lastInstructions: String?
    func editFailOpen(_ text: String, instructions: String) async throws -> String {
        lastInstructions = instructions; return text
    }
    func instructions() -> String? { lastInstructions }
}
/// Supplies a fixed example set regardless of limit.
private struct StubFewShot: FewShotProviding {
    let fixed: [FewShotExample]
    func examples(limit: Int) async -> [FewShotExample] { fixed }
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

// MARK: - Post-process + persist tests (new)

final class RunnerPostProcessTests: XCTestCase {
    private func rule(_ pattern: String, _ replacement: String) -> ReplacementRule {
        ReplacementRule(id: 0, profileID: "w", pattern: pattern, replacement: replacement,
                        isRegex: false, caseSensitive: false, wordBoundary: true, sortOrder: 0)
    }

    func testFullCycle_appliesRules_andPersistsViaSnapshot() async throws {
        let rec = FakeAudioRecorder()
        let tr = await makeTranscriber(FixedKit(text: "Quest rocks"),
                                       profileName: "Work", modelID: "m-work",
                                       rules: [rule("Quest", "Questable")])
        let paster = SpyPaster()
        let persister = SpyPersister()
        let runner = Runner(recorder: rec, transcriber: tr, paster: paster,
                            persister: persister, minHoldMs: 0)
        runner.onPress()
        rec.push([0.5])                    // non-empty so transcribe runs
        runner.onRelease()
        await waitUntilIdle(runner)

        let pasted = await paster.getCalls()
        XCTAssertEqual(pasted, ["Questable rocks"])
        let inserts = await persister.getInserts()
        XCTAssertEqual(inserts.count, 1)
        XCTAssertEqual(inserts.first?.profileName, "Work")
        XCTAssertEqual(inserts.first?.modelID, "m-work")
        XCTAssertEqual(inserts.first?.rawText, "Quest rocks")
        XCTAssertEqual(inserts.first?.finalText, "Questable rocks")
    }

    func testPersistenceCalledOnce_andPasteHappens() async throws {
        let rec = FakeAudioRecorder()
        let tr = await makeTranscriber(FixedKit(text: "hi"))
        let paster = SpyPaster()
        let persister = SpyPersister()
        let runner = Runner(recorder: rec, transcriber: tr, paster: paster,
                            persister: persister, minHoldMs: 0)
        runner.onPress()
        rec.push([0.5])
        runner.onRelease()
        await waitUntilIdle(runner)

        let pasteCalls = await paster.getCalls()
        let insertCount = await persister.getInserts().count
        XCTAssertEqual(pasteCalls, ["hi"])
        XCTAssertEqual(insertCount, 1)
    }
}

// MARK: - State-machine tests (migrated)

final class RunnerTests: XCTestCase {
    func testFullCycle_recordsTranscribesPastes() async throws {
        let rec = FakeAudioRecorder()
        let tr = await makeTranscriber(FixedKit(text: "hello world"))
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            persister: NoOpPersister(),
            minHoldMs: 0,
            clock: { Date(timeIntervalSince1970: 0) }
        )

        runner.onPress()
        rec.push([0.5])                    // non-empty so transcribe runs
        // Snapshot state before release.
        XCTAssertEqual(runner.state, .recording)
        runner.onRelease()
        await waitUntilIdle(runner)

        let pasted = await paster.getCalls()
        XCTAssertEqual(pasted, ["hello world"])
        XCTAssertEqual(runner.state, .idle)
    }

    func testShortPress_discardsAndDoesNotPaste() async {
        let rec = FakeAudioRecorder()
        let tr = await makeTranscriber(FixedKit(text: "x"))
        let paster = SpyPaster()
        let testClock = TestClock()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            persister: NoOpPersister(),
            minHoldMs: 200,
            clock: { testClock.date() }
        )

        runner.onPress()
        testClock.now = 0.05    // 50 ms — under threshold
        runner.onRelease()
        await waitUntilIdle(runner)

        let calls0 = await paster.getCalls()
        XCTAssertEqual(calls0, [])
        XCTAssertEqual(runner.state, .idle)
    }

    func testEmptyTranscript_doesNotPaste() async throws {
        let rec = FakeAudioRecorder()
        let tr = await makeTranscriber(FixedKit(text: "   "))
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            persister: NoOpPersister(),
            minHoldMs: 0
        )

        runner.onPress()
        rec.push([0.5])                    // non-empty so transcribe runs; kit returns "   "
        runner.onRelease()
        await waitUntilIdle(runner)

        let callsEmpty = await paster.getCalls()
        XCTAssertEqual(callsEmpty, [])
    }

    func testPressDuringTranscribing_isRejected() async throws {
        let rec = FakeAudioRecorder()
        let kit = BlockingKit(text: "result")
        let tr = await makeTranscriber(kit)
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            persister: NoOpPersister(),
            minHoldMs: 0
        )

        runner.onPress()
        rec.push([0.5])                    // non-empty so transcribe runs (and blocks)
        runner.onRelease()
        // Wait until the worker has actually entered transcribe and is blocked.
        try await waitForState(runner, .transcribing)

        runner.onPress()                    // must be rejected
        XCTAssertEqual(runner.state, .transcribing)
        XCTAssertEqual(rec.startCount, 1)   // not 2

        kit.unblock()                       // let the worker finish
        await waitUntilIdle(runner)
        let callsResult = await paster.getCalls()
        XCTAssertEqual(callsResult, ["result"])
    }

    func testPressDuringStopping_isRejected() async throws {
        let rec = SlowStopRecorder()
        let tr = await makeTranscriber(FixedKit(text: "ok"))
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            persister: NoOpPersister(),
            minHoldMs: 0
        )

        runner.onPress()
        let releaseTask = Task.detached(priority: .userInitiated) {
            runner.onRelease()
        }
        try await waitForState(runner, .stopping)
        runner.onPress()                    // must be rejected
        XCTAssertEqual(runner.state, .stopping)
        XCTAssertEqual(rec.startCount, 1)

        rec.unblockStop()
        await releaseTask.value
        await waitUntilIdle(runner)
    }

    func testTranscribeException_caughtLoopContinues() async throws {
        let rec = FakeAudioRecorder()
        let tr = await makeTranscriber(ThrowingKit())
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            persister: NoOpPersister(),
            minHoldMs: 0
        )

        runner.onPress()
        rec.push([0.5])                    // non-empty so transcribe runs (and throws)
        runner.onRelease()
        await waitUntilIdle(runner)

        let callsAfterThrow = await paster.getCalls()
        XCTAssertEqual(callsAfterThrow, [])
        // Second cycle still works.
        let tr2 = await makeTranscriber(FixedKit(text: "second"))
        let runner2 = Runner(
            recorder: rec,
            transcriber: tr2,
            paster: paster,
            persister: NoOpPersister(),
            minHoldMs: 0
        )
        runner2.onPress()
        rec.push([0.5])                    // non-empty so transcribe runs
        runner2.onRelease()
        await waitUntilIdle(runner2)
        let callsSecond = await paster.getCalls()
        XCTAssertEqual(callsSecond, ["second"])
    }

    func testShutdown_abortsRecordingAndReturnsToIdle() async {
        let rec = FakeAudioRecorder()
        let tr = await makeTranscriber(FixedKit())
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            persister: NoOpPersister(),
            minHoldMs: 0
        )

        runner.onPress()
        XCTAssertEqual(runner.state, .recording)
        runner.shutdown()
        XCTAssertEqual(runner.state, .idle)
        XCTAssertGreaterThanOrEqual(rec.abortCount, 1)
    }
}

// MARK: - LLM-edit tests

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
        XCTAssertEqual(pasted, [])
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

    func testEnabled_fewShotExamplesAugmentEditorInstructions() async throws {
        let rec = FakeAudioRecorder()
        let tr = await makeTranscriberWithEdit(FixedKit(text: "raw words"),
                                               enabled: true, prompt: "BASE PROMPT")
        let editor = CapturingEditor()
        let fewShot = StubFewShot(fixed: [FewShotExample(raw: "raw ex", corrected: "corrected ex")])
        let runner = Runner(recorder: rec, transcriber: tr, paster: SpyPaster(),
                            persister: NoOpPersister(), editor: editor,
                            fewShot: fewShot, minHoldMs: 0)
        runner.onPress(); rec.push([0.5]); runner.onRelease()
        await waitUntilIdle(runner)

        let instr = await editor.instructions()
        XCTAssertNotNil(instr)
        XCTAssertTrue(instr?.contains("BASE PROMPT") ?? false)    // base kept
        XCTAssertTrue(instr?.contains("corrected ex") ?? false)   // example injected
    }

    func testRulesRunAfterLLM_ruleWins() async throws {
        let rec = FakeAudioRecorder()
        let tr = await makeTranscriberWithEdit(FixedKit(text: "x"), enabled: true,
                                               rules: [rule("Quest", "Questable")])
        let paster = SpyPaster()
        let runner = Runner(recorder: rec, transcriber: tr, paster: paster,
                            persister: NoOpPersister(), editor: StubEditor(edited: "Quest rocks"),
                            minHoldMs: 0)
        runner.onPress(); rec.push([0.5]); runner.onRelease()
        await waitUntilIdle(runner)
        let pasted = await paster.getCalls()
        XCTAssertEqual(pasted, ["Questable rocks"])
    }
}
