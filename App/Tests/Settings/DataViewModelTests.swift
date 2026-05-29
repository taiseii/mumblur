import XCTest
import GRDB
@testable import Mumblur
import MumblurCore

@MainActor
final class DataViewModelTests: XCTestCase {
    func testRetentionToggle_persistsToDB() async throws {
        let db = try AppDatabase(location: .inMemory)
        let vm = DataViewModel(deps: .init(
            loadStats: { nil },
            loadRetention: {
                let on = (try? db.read { conn in
                    (try Int.fetchOne(conn, sql: "SELECT enabled FROM retention_policy WHERE singleton=1") ?? 0) == 1
                }) ?? false
                return (on, "days", 30)
            },
            setRetention: { enabled, kind, value in
                try? db.write { conn in
                    try conn.execute(sql:
                        "UPDATE retention_policy SET enabled=?, kind=?, value=? WHERE singleton=1",
                        arguments: [enabled ? 1 : 0, kind, value])
                }
            }))
        await vm.setRetention(enabled: true)
        let enabled = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT enabled FROM retention_policy WHERE singleton=1") ?? 0
        }
        XCTAssertEqual(enabled, 1)
    }

    func testLoadCorrection_populatesEditableField() async {
        var requested: Int64?
        let vm = DataViewModel(deps: .init(
            loadStats: { nil }, loadRetention: { (false, "days", 30) }, setRetention: { _, _, _ in },
            loadCorrection: { id in requested = id; return "prior text" }))
        await vm.loadCorrection(for: 42)
        XCTAssertEqual(vm.correctionText, "prior text")
        XCTAssertEqual(requested, 42)
    }

    func testSaveCorrection_nonEmpty_upsertsTrimmedText() async {
        var upserted: (Int64, String)?
        var deleted: Int64?
        let vm = DataViewModel(deps: .init(
            loadStats: { nil }, loadRetention: { (false, "days", 30) }, setRetention: { _, _, _ in },
            upsertCorrection: { id, t in upserted = (id, t) },
            deleteCorrection: { id in deleted = id }))
        vm.correctionText = "  hello world  "
        await vm.saveCorrection(for: 7)
        XCTAssertEqual(upserted?.0, 7)
        XCTAssertEqual(upserted?.1, "hello world")   // ends trimmed, inner text kept
        XCTAssertNil(deleted)                         // not a discard
    }

    func testSaveCorrection_emptyOrWhitespace_deletesInsteadOfStoringEmpty() async {
        var upsertCalled = false
        var deleted: Int64?
        let vm = DataViewModel(deps: .init(
            loadStats: { nil }, loadRetention: { (false, "days", 30) }, setRetention: { _, _, _ in },
            upsertCorrection: { _, _ in upsertCalled = true },
            deleteCorrection: { id in deleted = id }))
        vm.correctionText = "   \n  "
        await vm.saveCorrection(for: 9)
        XCTAssertEqual(deleted, 9)        // discarded as training data
        XCTAssertFalse(upsertCalled)      // never store an empty target
    }

    func testLoad_populatesRecentAndStorageRoot() async throws {
        let db = try AppDatabase(location: .inMemory)
        let settings = SettingsStore(database: db)
        let store = TranscriptStore(database: db)
        let p = try await settings.create(name: "P", modelID: "m")
        try await store.insertTextOnly(profileID: p.id, profileNameSnapshot: p.name,
            promptSnapshot: nil, startedAt: Date(), durationMs: 1,
            modelID: "m", language: nil, rawText: "raw", finalText: "final")
        let root = URL(fileURLWithPath: "/tmp/mumblur-test")
        let vm = DataViewModel(deps: .init(
            loadStats: { nil },
            loadRetention: { (false, "days", 30) },
            setRetention: { _, _, _ in },
            loadRecent: { (try? await store.recent(limit: 50)) ?? [] },
            storageRoot: root))
        await vm.load()
        XCTAssertEqual(vm.recent.count, 1)
        XCTAssertEqual(vm.recent.first?.finalText, "final")
        XCTAssertEqual(vm.storageRoot, root)
    }
}
