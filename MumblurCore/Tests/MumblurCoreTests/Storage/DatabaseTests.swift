// MumblurCore/Tests/MumblurCoreTests/Storage/DatabaseTests.swift
import XCTest
import GRDB
@testable import MumblurCore

final class DatabaseTests: XCTestCase {

    private func makeDB() throws -> AppDatabase {
        try AppDatabase(location: .inMemory)
    }

    func testForeignKeysAreEnforced() throws {
        let db = try makeDB()
        try db.write { conn in
            let v: Int = try Int.fetchOne(conn, sql: "PRAGMA foreign_keys") ?? 0
            XCTAssertEqual(v, 1)
        }
    }

    func testMigrationApplies_AndIsIdempotent() throws {
        let db = try makeDB()
        try db.runMigrations()
        try db.runMigrations()  // second call must be a no-op
        try db.read { conn in
            let names = try String.fetchAll(conn,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            XCTAssertEqual(Set(names), [
                "app_setting", "calibration_run", "calibration_sample",
                "transcript_correction",
                "grdb_migrations", "profile", "replacement_rule",
                "retention_policy", "transcript", "vocab_term"
            ])
            let retention = try Row.fetchOne(conn, sql: "SELECT * FROM retention_policy")
            XCTAssertEqual(retention?["enabled"], 0)
            XCTAssertEqual(retention?["kind"], "days")
            XCTAssertEqual(retention?["value"], 30)
        }
    }

    func testProfileNameUniqueness_RespectsSoftDelete() throws {
        let db = try makeDB()
        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO profile(id,name,model_id,created_at,updated_at)
                VALUES ('a','Work','openai_whisper-large-v3-turbo',1,1)
            """)
            // Same name while active → must fail.
            XCTAssertThrowsError(try conn.execute(sql: """
                INSERT INTO profile(id,name,model_id,created_at,updated_at)
                VALUES ('b','work','openai_whisper-large-v3-turbo',1,1)
            """))
            // Soft-delete 'a', then 'Work' must be reusable.
            try conn.execute(sql: "UPDATE profile SET deleted_at=2 WHERE id='a'")
            try conn.execute(sql: """
                INSERT INTO profile(id,name,model_id,created_at,updated_at)
                VALUES ('c','Work','openai_whisper-large-v3-turbo',3,3)
            """)
        }
    }

    func testRetentionPolicyChecks() throws {
        let db = try makeDB()
        try db.write { conn in
            XCTAssertThrowsError(try conn.execute(sql:
                "UPDATE retention_policy SET kind='weeks' WHERE singleton=1"))
            XCTAssertThrowsError(try conn.execute(sql:
                "UPDATE retention_policy SET enabled=2 WHERE singleton=1"))
            XCTAssertThrowsError(try conn.execute(sql:
                "UPDATE retention_policy SET value=-1 WHERE singleton=1"))
        }
    }

    func testTranscriptAudioMetadataIsAllOrNothing() throws {
        let db = try makeDB()
        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO profile(id,name,model_id,created_at,updated_at)
                VALUES ('p','P','m',1,1)
            """)
            // Partial audio metadata must fail.
            XCTAssertThrowsError(try conn.execute(sql: """
                INSERT INTO transcript(profile_id,started_at,duration_ms,model_id,
                    raw_text,final_text,audio_rel_path)
                VALUES ('p',1,1,'m','r','f','clips/x.wav')
            """))
            // All-NULL (no audio) is OK.
            try conn.execute(sql: """
                INSERT INTO transcript(profile_id,started_at,duration_ms,model_id,raw_text,final_text)
                VALUES ('p',1,1,'m','r','f')
            """)
        }
    }

    func testCalibrationSampleDualResultInvariant() throws {
        let db = try makeDB()
        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO profile(id,name,model_id,created_at,updated_at)
                VALUES ('p','P','m',1,1)
            """)
            try conn.execute(sql: """
                INSERT INTO calibration_run(profile_id,profile_name_snapshot,script_id,
                    script_hash,started_at,model_id)
                VALUES ('p','P','s1','h',1,'m')
            """)
            // 'recorded' with a produced text must fail.
            XCTAssertThrowsError(try conn.execute(sql: """
                INSERT INTO calibration_sample(run_id,sample_index,set_role,status,ground_truth,
                    raw_text,duration_ms,audio_rel_path,audio_bytes,audio_sha256,
                    sample_rate_hz,channels,pcm_encoding)
                VALUES (1,0,'mining','recorded','gt',
                    'whoops',1,'p',1,
                    '0000000000000000000000000000000000000000000000000000000000000000',
                    16000,1,'pcm_s16le')
            """))
            // 'transcribed' without a wer must fail.
            XCTAssertThrowsError(try conn.execute(sql: """
                INSERT INTO calibration_sample(run_id,sample_index,set_role,status,ground_truth,
                    raw_text,final_text,duration_ms,audio_rel_path,audio_bytes,audio_sha256,
                    sample_rate_hz,channels,pcm_encoding)
                VALUES (1,1,'eval','transcribed','gt','r','f',1,'p',1,
                    '0000000000000000000000000000000000000000000000000000000000000000',
                    16000,1,'pcm_s16le')
            """))
        }
    }
}
