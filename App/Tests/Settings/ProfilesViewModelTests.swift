// App/Tests/Settings/ProfilesViewModelTests.swift
import XCTest
@testable import Mumblur
import MumblurCore

@MainActor
final class ProfilesViewModelTests: XCTestCase {

    func testSwitchTo_callsCoordinator() async throws {
        var observed: Profile?
        let vm = ProfilesViewModel(coordinator: .init(
            switchActive: { observed = $0 },
            createProfile: { _, _ in throw CocoaError(.featureUnsupported) },
            softDelete: { _ in throw CocoaError(.featureUnsupported) }))
        let p = Profile(id: "x", name: "X", language: nil, modelID: "m",
                        initialPrompt: nil, vocab: [], rules: [],
                        createdAt: .now, updatedAt: .now, deletedAt: nil)
        await vm.switchTo(p)
        XCTAssertEqual(observed?.id, "x")
    }
}
