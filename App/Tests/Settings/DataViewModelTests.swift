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
}
