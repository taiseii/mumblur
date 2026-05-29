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

    /// A user's intended text for a transcript, captured after the fact.
    /// Latest-wins: at most one per transcript (UNIQUE(transcript_id)).
    public struct Correction: Sendable, Identifiable {
        public let id: Int64
        public let transcriptID: Int64
        public let correctedText: String
        public let updatedAt: Date
        public let source: String
    }

    /// A `(input, target)` example for tuning, joined from transcript + correction.
    public struct TrainingPair: Sendable {
        public let transcriptID: Int64
        public let rawText: String          // Whisper output -> LLM input
        public let correctedText: String    // user's target
        public let audioRelPath: String?    // -> ASR fine-tune input (nil if audio not retained)
        public let language: String?
        public let modelID: String
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

    /// Records (or replaces) the user's intended text for a transcript.
    /// Empty `correctedText` is allowed and means "discard as training data" — distinct
    /// from absence of a row, which means "not yet reviewed".
    public func upsertCorrection(transcriptID: Int64, correctedText: String,
                                 source: String = "manual") throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO transcript_correction(transcript_id, corrected_text, updated_at, source)
                VALUES (?,?,?,?)
                ON CONFLICT(transcript_id) DO UPDATE SET
                    corrected_text = excluded.corrected_text,
                    updated_at     = excluded.updated_at,
                    source         = excluded.source
            """, arguments: [transcriptID, correctedText,
                             Int64(Date().timeIntervalSince1970 * 1000), source])
        }
    }

    public func correction(for transcriptID: Int64) throws -> Correction? {
        try database.read { db in
            try GRDB.Row.fetchOne(db, sql: """
                SELECT id, transcript_id, corrected_text, updated_at, source
                FROM transcript_correction WHERE transcript_id = ?
            """, arguments: [transcriptID]).map { r in
                Correction(id: r["id"],
                           transcriptID: r["transcript_id"],
                           correctedText: r["corrected_text"],
                           updatedAt: Date(timeIntervalSince1970: Double(r["updated_at"] as Int64) / 1000.0),
                           source: r["source"])
            }
        }
    }

    /// Removes a transcript's correction (the user discarding it as training data).
    /// The transcript row itself is untouched.
    public func deleteCorrection(transcriptID: Int64) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM transcript_correction WHERE transcript_id = ?",
                           arguments: [transcriptID])
        }
    }

    /// Corrected transcripts as `(raw_text -> corrected_text)` training pairs, newest first.
    /// `requireAudio` restricts to transcripts whose audio was retained (for ASR tuning).
    public func trainingPairs(limit: Int? = nil, requireAudio: Bool = false) throws -> [TrainingPair] {
        try database.read { db in
            var sql = """
                SELECT t.id, t.raw_text, c.corrected_text, t.audio_rel_path, t.language, t.model_id
                FROM transcript_correction c
                JOIN transcript t ON t.id = c.transcript_id
                WHERE (? = 0 OR t.audio_rel_path IS NOT NULL)
                ORDER BY c.updated_at DESC, t.id DESC
            """
            var args: [DatabaseValueConvertible] = [requireAudio ? 1 : 0]
            if let limit { sql += " LIMIT ?"; args.append(limit) }
            return try GRDB.Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { r in
                TrainingPair(transcriptID: r["id"],
                             rawText: r["raw_text"],
                             correctedText: r["corrected_text"],
                             audioRelPath: r["audio_rel_path"],
                             language: r["language"],
                             modelID: r["model_id"])
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
