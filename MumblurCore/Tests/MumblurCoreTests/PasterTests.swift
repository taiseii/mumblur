import XCTest
import AppKit
@testable import MumblurCore

@MainActor
final class PasterTests: XCTestCase {
    /// Each test gets its own uniquely-named pasteboard so parallel runs can't
    /// clobber each other via the shared `.general` pasteboard.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard.withUniqueName()
    }

    func testPaste_writesToPasteboardAndCallsKeystroke() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let spy = KeystrokeSpy()
        let paster = Paster(keystroke: spy, pasteboard: pb)

        await paster.paste("hello mumblur")

        XCTAssertEqual(pb.string(forType: .string), "hello mumblur")
        XCTAssertEqual(spy.calls, ["cmd+v"])
    }

    func testPaste_emptyStringIsNoop() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("sentinel", forType: .string)
        let spy = KeystrokeSpy()
        let paster = Paster(keystroke: spy, pasteboard: pb)

        await paster.paste("")

        XCTAssertEqual(pb.string(forType: .string), "sentinel")
        XCTAssertEqual(spy.calls, [])
    }

    func testPaste_whitespaceOnlyIsNoop() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("sentinel2", forType: .string)
        let spy = KeystrokeSpy()
        let paster = Paster(keystroke: spy, pasteboard: pb)

        await paster.paste("   \n\t  ")

        XCTAssertEqual(pb.string(forType: .string), "sentinel2")
        XCTAssertEqual(spy.calls, [])
    }
}

/// Test helper. Records cmd+v calls instead of synthesizing real events.
final class KeystrokeSpy: KeystrokeSending, @unchecked Sendable {
    var calls: [String] = []
    func sendCmdV() {
        calls.append("cmd+v")
    }
}
