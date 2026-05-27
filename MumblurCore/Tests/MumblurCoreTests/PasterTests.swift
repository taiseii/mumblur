import XCTest
import AppKit
@testable import MumblurCore

@MainActor
final class PasterTests: XCTestCase {
    func testPaste_writesToPasteboardAndCallsKeystroke() async {
        let pb = NSPasteboard.general
        pb.clearContents()
        let spy = KeystrokeSpy()
        let paster = Paster(keystroke: spy)

        await paster.paste("hello mumblur")

        XCTAssertEqual(pb.string(forType: .string), "hello mumblur")
        XCTAssertEqual(spy.calls, ["cmd+v"])
    }

    func testPaste_emptyStringIsNoop() async {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("sentinel", forType: .string)
        let spy = KeystrokeSpy()
        let paster = Paster(keystroke: spy)

        await paster.paste("")

        XCTAssertEqual(pb.string(forType: .string), "sentinel")
        XCTAssertEqual(spy.calls, [])
    }

    func testPaste_whitespaceOnlyIsNoop() async {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("sentinel2", forType: .string)
        let spy = KeystrokeSpy()
        let paster = Paster(keystroke: spy)

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
