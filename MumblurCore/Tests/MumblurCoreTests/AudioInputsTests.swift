import XCTest
@testable import MumblurCore

final class AudioInputsTests: XCTestCase {
    private let a = AudioInputDevice(uid: "A", name: "Built-in")
    private let b = AudioInputDevice(uid: "B", name: "USB Mic")

    func testResolveInput_nilPreferred_returnsNil_meaningSystemDefault() {
        XCTAssertNil(AudioInputs.resolve(preferredUID: nil, available: [a, b]))
    }

    func testResolveInput_matchingUID_returnsThatDevice() {
        XCTAssertEqual(AudioInputs.resolve(preferredUID: "B", available: [a, b]), b)
    }

    func testResolveInput_missingUID_returnsNil_soCallerFallsBackToDefault() {
        XCTAssertNil(AudioInputs.resolve(preferredUID: "GONE", available: [a, b]))
    }
}
