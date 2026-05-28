import XCTest
@testable import MumblurCore

final class MumblurCoreTests: XCTestCase {
    func testVersionIsNonEmpty() {
        XCTAssertFalse(MumblurCoreInfo.version.isEmpty)
    }
}
