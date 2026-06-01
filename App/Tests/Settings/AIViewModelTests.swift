// App/Tests/Settings/AIViewModelTests.swift
import XCTest
@testable import Mumblur
import MumblurCore

@MainActor
final class AIViewModelTests: XCTestCase {

    private func makeVM(profileStoredPrompt: String?) -> AIViewModel {
        let profile = Profile(id: "p1", name: "Default", language: nil, modelID: "m",
                              initialPrompt: nil, vocab: [], rules: [],
                              llmEditEnabled: false,
                              llmEditPrompt: profileStoredPrompt,
                              createdAt: .init(timeIntervalSince1970: 0),
                              updatedAt: .init(timeIntervalSince1970: 0),
                              deletedAt: nil)
        return AIViewModel(deps: .init(
            loadConfig: { .default },
            saveConfig: { _ in },
            loadProfiles: { [profile] },
            activeProfileID: { "p1" },
            saveProfileAI: { _, _, _ in },
            testConnection: { _ in "" }))
    }

    func testLoad_emptyStoredPrompt_prefillsWithDefault() async {
        let vm = makeVM(profileStoredPrompt: nil)
        await vm.load()
        XCTAssertEqual(vm.profilePrompt, LLMEditConfig.defaultPrompt)
        XCTAssertTrue(vm.promptIsDefault)
    }

    func testLoad_storedCustomPrompt_keepsCustomText() async {
        let vm = makeVM(profileStoredPrompt: "Only fix punctuation.")
        await vm.load()
        XCTAssertEqual(vm.profilePrompt, "Only fix punctuation.")
        XCTAssertFalse(vm.promptIsDefault)
    }

    func testResetPromptToDefault_restoresDefaultText() async {
        let vm = makeVM(profileStoredPrompt: "Something custom.")
        await vm.load()
        vm.resetPromptToDefault()
        XCTAssertEqual(vm.profilePrompt, LLMEditConfig.defaultPrompt)
        XCTAssertTrue(vm.promptIsDefault)
    }

    func testSaveProfile_currentTextEqualsDefault_persistsNilSoStorageStaysClean() async {
        var stored: (String, Bool, String?)?
        let profile = Profile(id: "p1", name: "Default", language: nil, modelID: "m",
                              initialPrompt: nil, vocab: [], rules: [],
                              llmEditEnabled: false, llmEditPrompt: nil,
                              createdAt: .init(timeIntervalSince1970: 0),
                              updatedAt: .init(timeIntervalSince1970: 0),
                              deletedAt: nil)
        let vm = AIViewModel(deps: .init(
            loadConfig: { .default },
            saveConfig: { _ in },
            loadProfiles: { [profile] },
            activeProfileID: { "p1" },
            saveProfileAI: { id, enabled, prompt in stored = (id, enabled, prompt) },
            testConnection: { _ in "" }))
        await vm.load()
        XCTAssertEqual(vm.profilePrompt, LLMEditConfig.defaultPrompt)   // prefilled
        await vm.saveProfile()
        XCTAssertEqual(stored?.0, "p1")
        XCTAssertNil(stored?.2, "default-equal prompt should persist as nil so the DB doesn't hard-code an evolvable default")
    }
}
