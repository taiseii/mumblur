// MumblurCore/Sources/MumblurCore/Storage/TranscriptStore.swift
import Foundation
import GRDB

public actor TranscriptStore {
    public struct AudioMetadata: Sendable {
        public let relPath: String
        public let bytes: Int64
        public let sha256: String
        public let sampleRateHz: Int
        public let channels: Int
        public let pcmEncoding: String
        public init(relPath: String, bytes: Int64, sha256: String,
                    sampleRateHz: Int, channels: Int, pcmEncoding: String) {
            self.relPath = relPath; self.bytes = bytes; self.sha256 = sha256
            self.sampleRateHz = sampleRateHz; self.channels = channels; self.pcmEncoding = pcmEncoding
        }
    }

    public struct Stats: Sendable {
        public let count: Int
        public let audioCount: Int
        public let bytes: Int64
        public let oldestAt: Date?
        public let newestAt: Date?
    }

    public struct Row: Sendable, Identifiable {
        public let id: Int64
        public let startedAt: Date
        public let durationMs: Int
        public let profileNameSnapshot: String?
        public let modelID: String
        public let language: String?
        public let promptSnapshot: String?
        public let rawText: String
        public let finalText: String
        public let audioRelPath: String?
        public let audioBytes: Int64?
    }

    public enum RetentionPolicy: Sendable {
        case days(Int)
        case count(limit: Int)
    }

    private let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }

    public func insertTextOnly(profileID: String, profileNameSnapshot: String,
        promptSnapshot: String?, startedAt: Date, durationMs: Int,
        modelID: String, language: String?, rawText: String, finalText: String) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO transcript(profile_id, profile_name_snapshot, prompt_snapshot,
                    started_at, duration_ms, model_id, language, raw_text, final_text)
                VALUES (?,?,?,?,?,?,?,?,?)
            """, arguments: [profileID, profileNameSnapshot, promptSnapshot,
                             Int64(startedAt.timeIntervalSince1970 * 1000), durationMs,
                             modelID, language, rawText, finalText])
        }
    }

    public func insertWithAudio(profileID: String, profileNameSnapshot: String,
        promptSnapshot: String?, startedAt: Date, durationMs: Int,
        modelID: String, language: String?, rawText: String, finalText: String,
        audio: AudioMetadata) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO transcript(profile_id, profile_name_snapshot, prompt_snapshot,
                    started_at, duration_ms, model_id, language, raw_text, final_text,
                    audio_rel_path, audio_bytes, audio_sha256,
                    sample_rate_hz, channels, pcm_encoding)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, arguments: [profileID, profileNameSnapshot, promptSnapshot,
                             Int64(startedAt.timeIntervalSince1970 * 1000), durationMs,
                             modelID, language, rawText, finalText,
                             audio.relPath, audio.bytes, audio.sha256,
                             audio.sampleRateHz, audio.channels, audio.pcmEncoding])
        }
    }

    public func stats() throws -> Stats {
        try database.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript") ?? 0
            let audioCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM transcript WHERE audio_rel_path IS NOT NULL") ?? 0
            let bytes = try Int64.fetchOne(db,
                sql: "SELECT COALESCE(SUM(audio_bytes), 0) FROM transcript") ?? 0
            let oldest = try Int64.fetchOne(db, sql: "SELECT MIN(started_at) FROM transcript")
            let newest = try Int64.fetchOne(db, sql: "SELECT MAX(started_at) FROM transcript")
            func date(_ ms: Int64?) -> Date? { ms.map { Date(timeIntervalSince1970: Double($0) / 1000.0) } }
            return Stats(count: count, audioCount: audioCount, bytes: bytes,
                         oldestAt: date(oldest), newestAt: date(newest))
        }
    }

    /// Most-recent dictations first, capped at `limit`.
    public func recent(limit: Int) throws -> [Row] {
        try database.read { db in
            try GRDB.Row.fetchAll(db, sql: """
                SELECT id, started_at, duration_ms, profile_name_snapshot, model_id,
                       language, prompt_snapshot, raw_text, final_text,
                       audio_rel_path, audio_bytes
                FROM transcript ORDER BY started_at DESC, id DESC LIMIT ?
            """, arguments: [limit]).map { r in
                Row(id: r["id"],
                    startedAt: Date(timeIntervalSince1970: Double(r["started_at"] as Int64) / 1000.0),
                    durationMs: r["duration_ms"],
                    profileNameSnapshot: r["profile_name_snapshot"],
                    modelID: r["model_id"],
                    language: r["language"],
                    promptSnapshot: r["prompt_snapshot"],
                    rawText: r["raw_text"],
                    finalText: r["final_text"],
                    audioRelPath: r["audio_rel_path"],
                    audioBytes: r["audio_bytes"])
            }
        }
    }

    public func allAudioRelPaths() throws -> Set<String> {
        try database.read { db in
            Set(try String.fetchAll(db,
                sql: "SELECT audio_rel_path FROM transcript WHERE audio_rel_path IS NOT NULL"))
        }
    }

    /// Deletes transcript rows according to `policy`, then asks `audio` to clean up
    /// orphaned WAV files. Audio policy stays consistent with row policy.
    public func sweep(policy: RetentionPolicy, audio: AudioStore) async throws {
        try database.write { db in
            switch policy {
            case .days(let days):
                let cutoffMs = Int64((Date().addingTimeInterval(-Double(days) * 86400))
                    .timeIntervalSince1970 * 1000)
                try db.execute(sql: "DELETE FROM transcript WHERE started_at < ?",
                               arguments: [cutoffMs])
            case .count(let limit):
                try db.execute(sql: """
                    DELETE FROM transcript WHERE id NOT IN (
                        SELECT id FROM transcript ORDER BY started_at DESC LIMIT ?
                    )
                """, arguments: [limit])
            }
        }
        try await audio.cleanupOrphans(referencedRelPaths: { try await self.allAudioRelPaths() })
    }
}
