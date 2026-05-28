import XCTest
@testable import Mumblur
import MumblurCore

@MainActor
final class TuningViewModelTests: XCTestCase {
    func testStart_enqueuesCalibrationRun() async {
        var started = false
        let vm = TuningViewModel(deps: .init(
            startCalibration: { started = true },
            loadRuns: { [] }))
        await vm.start()
        XCTAssertTrue(started)
    }
}
