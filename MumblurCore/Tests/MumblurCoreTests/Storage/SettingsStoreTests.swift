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
}
