// MumblurCore/Sources/MumblurCore/Storage/MigrationsV3.swift
import GRDB

extension DatabaseMigrator {
    mutating func registerV3() {
        registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE transcript_correction (
                    id              INTEGER PRIMARY KEY,
                    transcript_id   INTEGER NOT NULL REFERENCES transcript(id) ON DELETE CASCADE,
                    corrected_text  TEXT    NOT NULL,
                    updated_at      INTEGER NOT NULL CHECK(updated_at >= 0),
                    source          TEXT    NOT NULL DEFAULT 'manual',
                    UNIQUE(transcript_id)
                );
                CREATE INDEX idx_correction_transcript ON transcript_correction(transcript_id);
            """)
        }
    }
}
