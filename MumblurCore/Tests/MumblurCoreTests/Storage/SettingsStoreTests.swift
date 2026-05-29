// MumblurCore/Tests/MumblurCoreTests/Storage/SettingsStoreTests.swift
import XCTest
@testable import MumblurCore

final class SettingsStoreTests: XCTestCase {

    private func makeStore() throws -> SettingsStore {
        let db = try AppDatabase(location: .inMemory)
        return SettingsStore(database: db)
    }

    func testCreate_seedsDefaultsAndReturnsProfile() async throws {
        let store = try makeStore()
        let p = try await store.create(name: "Work", modelID: "openai_whisper-large-v3-turbo")
        XCTAssertEqual(p.name, "Work")
        XCTAssertEqual(p.vocab, [])
        XCTAssertNil(p.deletedAt)
    }

    func testListActive_excludesSoftDeleted() async throws {
        let store = try makeStore()
        let a = try await store.create(name: "A", modelID: "m")
        _ = try await store.create(name: "B", modelID: "m")
        try await store.softDelete(profileID: a.id)
        let active = try await store.listActive()
        XCTAssertEqual(active.map(\.name), ["B"])
    }

    func testActiveProfileID_persistsAcrossReads() async throws {
        let store = try makeStore()
        let a = try await store.create(name: "A", modelID: "m")
        try await store.setActiveProfileID(a.id)
        let got = try await store.activeProfileID()
        XCTAssertEqual(got, a.id)
    }

    func testSoftDelete_thenCreateSameName_succeeds() async throws {
        let store = try makeStore()
        _ = try await store.create(name: "Keeper", modelID: "m")   // keeps lastActive() > 1 so the delete is allowed
        let a = try await store.create(name: "Work", modelID: "m")
        try await store.softDelete(profileID: a.id)
        let b = try await store.create(name: "Work", modelID: "m")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testCreate_duplicateActiveName_throws() async throws {
        let store = try makeStore()
        _ = try await store.create(name: "Work", modelID: "m")
        do {
            _ = try await store.create(name: "work", modelID: "m")
            XCTFail("expected duplicate-name error")
        } catch {}
    }

    func testHardPurge_removesProfileAndAllItsData() async throws {
        let store = try makeStore()
        let a = try await store.create(name: "A", modelID: "m")
        try await store.addVocab(profileID: a.id, term: "Questable")
        try await store.hardPurge(profileID: a.id)
        let active = try await store.listActive()
        XCTAssertTrue(active.isEmpty)
        let count = try await store.vocabCount(profileID: a.id)
        XCTAssertEqual(count, 0)
    }

    // --- REVISION v2 tests ---

    func testSoftDelete_lastActiveProfile_throws() async throws {
        let store = try makeStore()
        let a = try await store.create(name: "Only", modelID: "m")
        do {
            try await store.softDelete(profileID: a.id)
            XCTFail("expected cannotDeleteLastActive")
        } catch SettingsStoreError.cannotDeleteLastActive {
            // expected
        }
    }

    func testGet_softDeleted_returnsNilUnlessIncludeDeleted() async throws {
        let store = try makeStore()
        _ = try await store.create(name: "Keeper", modelID: "m")
        let a = try await store.create(name: "Gone", modelID: "m")
        try await store.softDelete(profileID: a.id)
        let hidden = try await store.get(profileID: a.id)
        XCTAssertNil(hidden)
        let shown = try await store.get(profileID: a.id, includeDeleted: true)
        XCTAssertNotNil(shown)
    }

    func testLLMServerConfig_roundTrips_andClampsTimeout() async throws {
        let db = try AppDatabase(location: .inMemory)
        let store = SettingsStore(database: db)
        let initial = try await store.llmServerConfig()
        XCTAssertEqual(initial, .default)  // unset → default
        try await store.setLLMServerConfig(
            LLMServerConfig(enabled: true, baseURL: "http://x:1", model: "q", timeoutMs: 999_999))
        let back = try await store.llmServerConfig()
        XCTAssertEqual(back.enabled, true)
        XCTAssertEqual(back.baseURL, "http://x:1")
        XCTAssertEqual(back.model, "q")
        XCTAssertEqual(back.timeoutMs, 60_000)   // clamped
    }

    func testLLMServerConfig_roundTripsNewAdvancedFields() async throws {
        let db = try AppDatabase(location: .inMemory)
        let store = SettingsStore(database: db)

        // Defaults when unset
        let initial = try await store.llmServerConfig()
        XCTAssertNil(initial.maxTokens)
        XCTAssertNil(initial.temperature)
        XCTAssertEqual(initial.extraBodyJSON, "")
        XCTAssertEqual(initial.requestTemplate, "")
        XCTAssertEqual(initial.contentPath, "/choices/0/message/content")
        XCTAssertEqual(initial.contentFallbackPath, "")

        try await store.setLLMServerConfig(
            LLMServerConfig(enabled: true, baseURL: "http://x:1", model: "q", timeoutMs: 5000,
                            maxTokens: 512, temperature: 0.4,
                            extraBodyJSON: "{\"top_p\":0.9}",
                            requestTemplate: "{\"model\":\"{{model}}\"}",
                            contentPath: "/choices/0/text",
                            contentFallbackPath: "/choices/0/message/reasoning_content"))
        let back = try await store.llmServerConfig()
        XCTAssertEqual(back.maxTokens, 512)
        XCTAssertEqual(back.temperature, 0.4)
        XCTAssertEqual(back.extraBodyJSON, "{\"top_p\":0.9}")
        XCTAssertEqual(back.requestTemplate, "{\"model\":\"{{model}}\"}")
        XCTAssertEqual(back.contentPath, "/choices/0/text")
        XCTAssertEqual(back.contentFallbackPath, "/choices/0/message/reasoning_content")

        // Empty/garbage int/double → nil on read
        try await store.setLLMServerConfig(
            LLMServerConfig(enabled: false, baseURL: "http://x", model: "", timeoutMs: 5000,
                            maxTokens: nil, temperature: nil))
        let cleared = try await store.llmServerConfig()
        XCTAssertNil(cleared.maxTokens)
        XCTAssertNil(cleared.temperature)
    }

    func testUpdate_roundTripsLLMEditFields() async throws {
        let db = try AppDatabase(location: .inMemory)
        let store = SettingsStore(database: db)
        var p = try await store.create(name: "Work", modelID: "m")
        p.llmEditEnabled = true
        p.llmEditPrompt = "Tidy it up"
        try await store.update(p)
        let back = try await store.get(profileID: p.id)
        XCTAssertEqual(back?.llmEditEnabled, true)
        XCTAssertEqual(back?.llmEditPrompt, "Tidy it up")
    }
}
