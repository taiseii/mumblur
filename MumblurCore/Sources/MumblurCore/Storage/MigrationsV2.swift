// MumblurCore/Sources/MumblurCore/Storage/MigrationsV2.swift
import GRDB

extension DatabaseMigrator {
    mutating func registerV2() {
        registerMigration("v2") { db in
            try db.execute(sql: """
                ALTER TABLE profile ADD COLUMN llm_edit_enabled INTEGER NOT NULL DEFAULT 0
                    CHECK(llm_edit_enabled IN (0,1));
                ALTER TABLE profile ADD COLUMN llm_edit_prompt  TEXT;
            """)
        }
    }
}
