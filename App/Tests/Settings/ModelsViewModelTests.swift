import XCTest
@testable import Mumblur
import MumblurCore

@MainActor
final class ModelsViewModelTests: XCTestCase {
    func testInstall_callsLoaderWithProgress() async {
        var installed: String?
        let vm = ModelsViewModel(deps: .init(list: { [] }, install: { installed = $0 }))
        await vm.install(modelID: "openai_whisper-tiny")
        XCTAssertEqual(installed, "openai_whisper-tiny")
    }
}
