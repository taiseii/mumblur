import XCTest
@testable import MumblurCore

final class AudioRecorderTests: XCTestCase {
    func testFakeRecorder_startThenStopReturnsBuffered() throws {
        let rec = FakeAudioRecorder()
        try rec.start()
        rec.push([0.1, 0.2, 0.3])
        rec.push([0.4, 0.5])
        let samples = rec.stop()
        XCTAssertEqual(samples, [0.1, 0.2, 0.3, 0.4, 0.5])
    }

    func testFakeRecorder_stopWithoutStartReturnsEmpty() {
        let rec = FakeAudioRecorder()
        let samples = rec.stop()
        XCTAssertEqual(samples, [])
    }

    func testFakeRecorder_secondCycleResetsBuffer() throws {
        let rec = FakeAudioRecorder()
        try rec.start()
        rec.push([1.0, 2.0])
        _ = rec.stop()
        try rec.start()
        rec.push([9.0])
        let samples = rec.stop()
        XCTAssertEqual(samples, [9.0])
    }

    func testFakeRecorder_abortIfActiveResetsState() throws {
        let rec = FakeAudioRecorder()
        try rec.start()
        rec.push([1.0])
        rec.abortIfActive()
        // After abort, a new cycle starts clean.
        try rec.start()
        let samples = rec.stop()
        XCTAssertEqual(samples, [])
    }

    func testFakeRecorder_startTwiceThrows() throws {
        let rec = FakeAudioRecorder()
        try rec.start()
        XCTAssertThrowsError(try rec.start())
    }

    func testFakeRecorder_stopErrorReturnsEmpty() throws {
        let rec = FakeAudioRecorder()
        try rec.start()
        rec.push([0.1])
        rec.simulateStopError = true
        XCTAssertEqual(rec.stop(), [])
        // And a fresh cycle works.
        try rec.start()
        XCTAssertEqual(rec.stop(), [])
    }
}

/// Fake recorder used in Runner tests too. Exposed `@testable` from MumblurCore.
final class FakeAudioRecorder: AudioRecording, @unchecked Sendable {
    private var chunks: [[Float]] = []
    private var active: Bool = false
    var simulateStopError: Bool = false
    var startCount: Int = 0
    var stopCount: Int = 0
    var abortCount: Int = 0

    func start() throws {
        if active { throw NSError(domain: "FakeAudioRecorder", code: 1) }
        chunks = []
        active = true
        startCount += 1
    }

    func push(_ samples: [Float]) {
        guard active else { return }
        chunks.append(samples)
    }

    func stop() -> [Float] {
        stopCount += 1
        guard active else { return [] }
        active = false
        if simulateStopError {
            chunks = []
            return []
        }
        let flat = chunks.flatMap { $0 }
        chunks = []
        return flat
    }

    func abortIfActive() {
        active = false
        chunks = []
        abortCount += 1
    }
}
