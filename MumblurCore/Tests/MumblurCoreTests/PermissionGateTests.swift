import XCTest
@testable import MumblurCore

final class PermissionGateTests: XCTestCase {
    func testEnsureAccessibility_returnsAValidResult() {
        // We can't deterministically grant/deny in a test, but we can confirm the
        // call returns one of the documented states without throwing or hanging.
        let result = PermissionGate.ensureAccessibility(prompt: false)
        XCTAssertTrue([.granted, .denied, .prompted].contains(result))
    }

    func testEnsureInputMonitoring_returnsAValidResult() {
        let result = PermissionGate.ensureInputMonitoring(prompt: false)
        XCTAssertTrue([.granted, .denied, .prompted].contains(result))
    }

    func testEnsureMicrophone_returnsAValidResult() async {
        let result = await PermissionGate.ensureMicrophone()
        XCTAssertTrue([.granted, .denied, .prompted].contains(result))
    }
}
