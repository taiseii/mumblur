import XCTest
@testable import MumblurCore

/// Sendable, lock-protected collector so @Sendable closures can record events
/// without violating Swift 6 strict-concurrency capture rules.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    func append(_ s: String) { lock.lock(); _values.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return _values }
}

final class HotkeyTests: XCTestCase {
    private let rightOption: CGKeyCode = 0x3D
    private let leftOption: CGKeyCode = 0x3A

    func testTargetKeycode_pressThenReleaseEmitsBoth() {
        let events = EventLog()
        var d = HotkeyDispatcher(
            targetKeycode: rightOption,
            onPress: { events.append("press") },
            onRelease: { events.append("release") }
        )
        d.handle(keycode: rightOption)
        d.handle(keycode: rightOption)
        XCTAssertEqual(events.values, ["press", "release"])
    }

    func testNonTargetKeycode_ignored() {
        let events = EventLog()
        var d = HotkeyDispatcher(
            targetKeycode: rightOption,
            onPress: { events.append("press") },
            onRelease: { events.append("release") }
        )
        d.handle(keycode: leftOption)
        d.handle(keycode: leftOption)
        XCTAssertEqual(events.values, [])
    }

    func testInterleavedRightAndLeftOption_tracksRightCorrectly() {
        // User scenario: holds Left Option, then taps Right Option once.
        // Aggregate .maskAlternate would be misleading; per-keycode toggle is correct.
        let events = EventLog()
        var d = HotkeyDispatcher(
            targetKeycode: rightOption,
            onPress: { events.append("press") },
            onRelease: { events.append("release") }
        )
        d.handle(keycode: leftOption)   // ignored
        d.handle(keycode: rightOption)  // press
        d.handle(keycode: rightOption)  // release
        d.handle(keycode: leftOption)   // ignored
        XCTAssertEqual(events.values, ["press", "release"])
    }

    func testThreePressesEmitsPressReleasePress() {
        // A flagsChanged stream that produces three down-transitions for the target
        // results in press, release, press (toggle semantics).
        let events = EventLog()
        var d = HotkeyDispatcher(
            targetKeycode: rightOption,
            onPress: { events.append("press") },
            onRelease: { events.append("release") }
        )
        d.handle(keycode: rightOption)
        d.handle(keycode: rightOption)
        d.handle(keycode: rightOption)
        XCTAssertEqual(events.values, ["press", "release", "press"])
    }
}
