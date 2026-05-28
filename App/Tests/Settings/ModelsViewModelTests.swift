import XCTest
@testable import Mumblur
import MumblurCore

@MainActor
final class ModelsViewModelTests: XCTestCase {
    func testLoad_populatesRows() async {
        let vm = ModelsViewModel(deps: .init(
            list: { [.init(id: "openai_whisper-tiny"), .init(id: "openai_whisper-large-v3-turbo")] },
            use: { _ in }))
        await vm.load()
        XCTAssertFalse(vm.loading)
        XCTAssertEqual(vm.rows.map(\.id), ["openai_whisper-tiny", "openai_whisper-large-v3-turbo"])
    }

    func testUse_callsCoordinatorAndRefreshes() async {
        var used: String?
        var listCalls = 0
        let vm = ModelsViewModel(deps: .init(
            list: { listCalls += 1; return [.init(id: "openai_whisper-tiny")] },
            use: { used = $0 }))
        await vm.use("openai_whisper-tiny")
        XCTAssertEqual(used, "openai_whisper-tiny")
        XCTAssertEqual(listCalls, 1)        // list re-fetched after use
        XCTAssertNil(vm.busyModelID)
    }
}
