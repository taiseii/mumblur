// MumblurCore/Tests/MumblurCoreTests/Storage/MigrationsV2Tests.swift
import XCTest
import GRDB
@testable import MumblurCore

final class MigrationsV2Tests: XCTestCase {
    func testV2_addsLLMColumns_withDefaults() throws {
        let db = try AppDatabase(location: .inMemory) // runMigrations() runs in init
        let (enabled, prompt): (Int, String?) = try db.write { d in
            try d.execute(sql: """
                INSERT INTO profile(id,name,model_id,created_at,updated_at)
                VALUES ('p','P','m',0,0)
            """)
            let row = try Row.fetchOne(d,
                sql: "SELECT llm_edit_enabled, llm_edit_prompt FROM profile WHERE id='p'")!
            return (row["llm_edit_enabled"], row["llm_edit_prompt"])
        }
        XCTAssertEqual(enabled, 0)
        XCTAssertNil(prompt)
    }
}
