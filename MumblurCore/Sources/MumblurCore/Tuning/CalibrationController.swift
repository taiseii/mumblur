// MumblurCore/Sources/MumblurCore/Tuning/CalibrationController.swift
import Foundation
import GRDB

public actor CalibrationController {

    public struct StepEvent: Sendable {
        public let index: Int
        public let total: Int
        public let prompt: String
    }

    private let database: AppDatabase
    private let settings: SettingsStore
    private let audio: AudioStore
    private let runner: Runner
    private let recorder: any AudioRecording
    private let transcriber: Transcriber
    private let postProcessor = TranscriptPostProcessor()
    private let wer = WERCalculator()
    private let miner = ErrorMiner()
    private let suggester = SuggestionGenerator()

    public init(database: AppDatabase, settings: SettingsStore, audio: AudioStore,
                runner: Runner, recorder: any AudioRecording, transcriber: Transcriber) {
        self.database = database; self.settings = settings; self.audio = audio
        self.runner = runner; self.recorder = recorder; self.transcriber = transcriber
    }

    public enum CalibrationError: Error { case snapshotMismatch, ceremonyAborted }

    /// Runs the ceremony. The caller must first request a swap via `ModelManager` so the
    /// `Transcriber` is serving this profile/model; pass that committed snapshot as
    /// `expectedSnapshot`. WER scoring uses `expectedSnapshot.rules` (source of truth).
    public func run(script: CalibrationScript,
                    requestedProfile: Profile,
                    expectedSnapshot: ServingSnapshot,
                    record: @Sendable (StepEvent) async throws -> [Float]
    ) async throws -> Int64 {
        guard expectedSnapshot.profileID == requestedProfile.id,
              expectedSnapshot.modelID == requestedProfile.modelID else {
            throw CalibrationError.snapshotMismatch
        }
        runner.setSuspended(true)
        defer { runner.setSuspended(false) }

        let runID: Int64 = try database.write { db in
            try db.execute(sql: """
                INSERT INTO calibration_run(profile_id, profile_name_snapshot,
                    language_snapshot, prompt_snapshot, script_id, script_hash,
                    started_at, model_id)
                VALUES(?,?,?,?,?,?,?,?)
            """, arguments: [expectedSnapshot.profileID, expectedSnapshot.profileName,
                             expectedSnapshot.language,
                             expectedSnapshot.prompt.sourceText.isEmpty
                                ? nil : expectedSnapshot.prompt.sourceText,
                             script.id, script.hash,
                             Int64(Date().timeIntervalSince1970 * 1000),
                             expectedSnapshot.modelID])
            return db.lastInsertedRowID
        }

        var evalRawWERs: [Double] = []
        var evalFinalWERs: [Double] = []

        for (i, sentence) in script.sentences.enumerated() {
            let event = StepEvent(index: i, total: script.sentences.count, prompt: sentence.text)
            do {
                let samples = try await record(event)
                let written = try await audio.write(samples: samples, sampleRateHz: 16000)
                try database.write { db in
                    try db.execute(sql: """
                        INSERT INTO calibration_sample(run_id,sample_index,set_role,status,
                            ground_truth,duration_ms,audio_rel_path,audio_bytes,audio_sha256,
                            sample_rate_hz,channels,pcm_encoding)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [runID, i, sentence.role.rawValue, "recorded",
                                     sentence.text, samples.count * 1000 / 16000,
                                     written.relPath, written.bytes, written.sha256,
                                     16000, 1, "pcm_s16le"])
                }
                let out = try await transcriber.transcribe(samples)
                let finalText = postProcessor.apply(out.rawText, rules: out.snapshot.rules)
                let rWer = wer.wer(reference: sentence.text, hypothesis: out.rawText)
                let fWer = wer.wer(reference: sentence.text, hypothesis: finalText)
                try database.write { db in
                    try db.execute(sql: """
                        UPDATE calibration_sample SET status='transcribed',
                            raw_text=?, final_text=?, raw_wer=?, final_wer=?
                        WHERE run_id=? AND sample_index=?
                    """, arguments: [out.rawText, finalText, rWer, fWer, runID, i])
                }
                if sentence.role == .eval {
                    evalRawWERs.append(rWer); evalFinalWERs.append(fWer)
                }
            } catch {
                try? database.write { db in
                    try db.execute(sql: """
                        UPDATE calibration_sample SET status='failed', error_message=?
                        WHERE run_id=? AND sample_index=?
                    """, arguments: [error.localizedDescription, runID, i])
                }
            }
        }

        let avgRaw = evalRawWERs.isEmpty ? nil : evalRawWERs.reduce(0, +) / Double(evalRawWERs.count)
        let avgFinal = evalFinalWERs.isEmpty ? nil : evalFinalWERs.reduce(0, +) / Double(evalFinalWERs.count)
        try database.write { db in
            try db.execute(sql: """
                UPDATE calibration_run SET completed_at=?, eval_raw_wer=?, eval_final_wer=?
                WHERE id=?
            """, arguments: [Int64(Date().timeIntervalSince1970 * 1000), avgRaw, avgFinal, runID])
        }
        return runID
    }

    public func suggestions(forRun id: Int64) async throws
        -> ([SuggestionGenerator.RuleSuggestion], [String]) {
        let samples: [ErrorMiner.Sample] = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ground_truth, raw_text FROM calibration_sample
                WHERE run_id=? AND set_role='mining' AND status='transcribed'
            """, arguments: [id]).map {
                ErrorMiner.Sample(groundTruth: $0["ground_truth"], raw: $0["raw_text"] ?? "")
            }
        }
        let subs = miner.mineSubstitutions(samples: samples)
        return (suggester.generateRules(from: subs), suggester.generateVocab(from: subs))
    }
}
