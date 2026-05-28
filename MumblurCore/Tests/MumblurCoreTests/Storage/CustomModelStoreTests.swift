import XCTest
@testable import MumblurCore

final class CustomModelStoreTests: XCTestCase {
    private func store() throws -> CustomModelStore {
        CustomModelStore(database: try AppDatabase(location: .inMemory))
    }

    func testEmptyByDefault() async throws {
        let s = try store()
        let all = try await s.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testAddAndGet_bothKinds() async throws {
        let s = try store()
        try await s.add(.folder(id: "my-local", path: "/models/my-local"))
        try await s.add(.repo(variant: "openai_whisper-tiny", repo: "me/my-repo"))

        let all = try await s.all()
        XCTAssertEqual(all.count, 2)
        let folder = try await s.get(id: "my-local")
        XCTAssertEqual(folder?.kind, .folder)
        XCTAssertEqual(folder?.folderPath, "/models/my-local")
        let repo = try await s.get(id: "openai_whisper-tiny")
        XCTAssertEqual(repo?.kind, .repo)
        XCTAssertEqual(repo?.repo, "me/my-repo")
    }

    func testAdd_replacesById() async throws {
        let s = try store()
        try await s.add(.repo(variant: "v", repo: "a/one"))
        try await s.add(.repo(variant: "v", repo: "b/two"))
        let all = try await s.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.repo, "b/two")
    }

    func testRemove() async throws {
        let s = try store()
        try await s.add(.folder(id: "x", path: "/x"))
        try await s.remove(id: "x")
        let remaining = try await s.all()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testPersistsAcrossStoreInstances() async throws {
        let db = try AppDatabase(location: .inMemory)
        let s1 = CustomModelStore(database: db)
        try await s1.add(.folder(id: "x", path: "/x"))
        let s2 = CustomModelStore(database: db)
        let reloaded = try await s2.all()
        XCTAssertEqual(reloaded.count, 1)
    }
}
