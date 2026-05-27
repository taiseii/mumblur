import XCTest
@testable import MumblurCore

final class RunnerTests: XCTestCase {
    func testFullCycle_recordsTranscribesPastes() async throws {
        let rec = FakeAudioRecorder()
        let tr = FakeTranscriber(text: "hello world")
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            minHoldMs: 0,
            clock: { Date(timeIntervalSince1970: 0) }
        )

        runner.onPress()
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
        let tr = FakeTranscriber(text: "x")
        let paster = SpyPaster()
        let testClock = TestClock()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
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
        let tr = FakeTranscriber(text: "   ")
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            minHoldMs: 0
        )

        runner.onPress()
        runner.onRelease()
        await waitUntilIdle(runner)

        let callsEmpty = await paster.getCalls()
        XCTAssertEqual(callsEmpty, [])
    }

    func testPressDuringTranscribing_isRejected() async throws {
        let rec = FakeAudioRecorder()
        let tr = BlockingTranscriber(text: "result")
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            minHoldMs: 0
        )

        runner.onPress()
        runner.onRelease()
        // Wait until the worker has actually entered transcribe and is blocked.
        try await waitForState(runner, .transcribing)

        runner.onPress()                    // must be rejected
        XCTAssertEqual(runner.state, .transcribing)
        XCTAssertEqual(rec.startCount, 1)   // not 2

        tr.unblock()                        // let the worker finish
        await waitUntilIdle(runner)
        let callsResult = await paster.getCalls()
        XCTAssertEqual(callsResult, ["result"])
    }

    func testPressDuringStopping_isRejected() async throws {
        let rec = SlowStopRecorder()
        let tr = FakeTranscriber(text: "ok")
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
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
        let tr = ThrowingTranscriber()
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            minHoldMs: 0
        )

        runner.onPress()
        runner.onRelease()
        await waitUntilIdle(runner)

        let callsAfterThrow = await paster.getCalls()
        XCTAssertEqual(callsAfterThrow, [])
        // Second cycle still works.
        let tr2 = FakeTranscriber(text: "second")
        let runner2 = Runner(
            recorder: rec,
            transcriber: tr2,
            paster: paster,
            minHoldMs: 0
        )
        runner2.onPress()
        runner2.onRelease()
        await waitUntilIdle(runner2)
        let callsSecond = await paster.getCalls()
        XCTAssertEqual(callsSecond, ["second"])
    }

    func testShutdown_abortsRecordingAndReturnsToIdle() async {
        let rec = FakeAudioRecorder()
        let tr = FakeTranscriber()
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            minHoldMs: 0
        )

        runner.onPress()
        XCTAssertEqual(runner.state, .recording)
        runner.shutdown()
        XCTAssertEqual(runner.state, .idle)
        XCTAssertGreaterThanOrEqual(rec.abortCount, 1)
    }

    // MARK: - Helpers

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
}

// MARK: - Test helpers

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: TimeInterval = 0
    var now: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); _now = newValue; lock.unlock() }
    }
    func date() -> Date { Date(timeIntervalSince1970: now) }
}

final class FakeTranscriber: Transcribing, @unchecked Sendable {
    private let text: String
    private(set) var calls: [[Float]] = []
    private let lock = NSLock()

    init(text: String = "hello") { self.text = text }

    func transcribe(_ samples: [Float]) async throws -> String {
        lock.withLock { calls.append(samples) }
        return text
    }
}

final class BlockingTranscriber: Transcribing, @unchecked Sendable {
    private let text: String
    private let unblockEvent = AsyncStream<Void>.makeStream()

    init(text: String) { self.text = text }

    func transcribe(_ samples: [Float]) async throws -> String {
        var it = unblockEvent.stream.makeAsyncIterator()
        _ = await it.next()
        return text
    }

    func unblock() {
        unblockEvent.continuation.yield(())
        unblockEvent.continuation.finish()
    }
}

final class ThrowingTranscriber: Transcribing, @unchecked Sendable {
    struct Boom: Error {}
    func transcribe(_ samples: [Float]) async throws -> String { throw Boom() }
}

actor SpyPaster: Pasting {
    var calls: [String] = []
    func paste(_ text: String) async {
        calls.append(text)
    }
    func getCalls() -> [String] { calls }
}

final class SlowStopRecorder: AudioRecording, @unchecked Sendable {
    private let stopGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _active = false
    private var _startCount = 0

    var startCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _startCount
    }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        _active = true
        _startCount += 1
    }

    func stop() -> [Float] {
        stopGate.wait()
        lock.lock(); defer { lock.unlock() }
        _active = false
        return [0.0]
    }

    func abortIfActive() {
        lock.lock(); defer { lock.unlock() }
        _active = false
    }

    func unblockStop() { stopGate.signal() }
}
