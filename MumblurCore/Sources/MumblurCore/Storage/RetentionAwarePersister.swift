// MumblurCore/Sources/MumblurCore/Storage/RetentionAwarePersister.swift
import Foundation
import GRDB
import os

public actor RetentionAwarePersister: DictationPersisting {
    private let database: AppDatabase
    private let transcripts: TranscriptStore
    private let audio: AudioStore

    public init(database: AppDatabase, transcripts: TranscriptStore, audio: AudioStore) {
        self.database = database; self.transcripts = transcripts; self.audio = audio
    }

    public func persist(samples: [Float], snapshot: ServingSnapshot,
                        startedAt: Date, durationMs: Int,
                        rawText: String, finalText: String) async {
        let enabled = (try? readRetentionEnabled()) ?? false
        if !enabled {
            await insertTextOnlyFallback(snapshot: snapshot, startedAt: startedAt,
                                         durationMs: durationMs, rawText: rawText, finalText: finalText)
            return
        }
        do {
            let written = try await audio.write(samples: samples, sampleRateHz: 16000)
            do {
                try await transcripts.insertWithAudio(
                    profileID: snapshot.profileID, profileNameSnapshot: snapshot.profileName,
                    promptSnapshot: snapshot.prompt.sourceText.isEmpty ? nil : snapshot.prompt.sourceText,
                    startedAt: startedAt, durationMs: durationMs,
                    modelID: snapshot.modelID, language: snapshot.language,
                    rawText: rawText, finalText: finalText,
                    audio: .init(relPath: written.relPath, bytes: written.bytes,
                                 sha256: written.sha256, sampleRateHz: 16000,
                                 channels: 1, pcmEncoding: "pcm_s16le"))
            } catch {
                // Compensating delete — keep the FS consistent with the DB.
                try? FileManager.default.removeItem(at: written.absoluteURL)
                Logger.app.error("transcript insert failed; removed WAV: \(error.localizedDescription)")
                await insertTextOnlyFallback(snapshot: snapshot, startedAt: startedAt,
                                             durationMs: durationMs, rawText: rawText, finalText: finalText)
            }
        } catch {
            Logger.app.error("audio write failed; falling back to text-only: \(error.localizedDescription)")
            await insertTextOnlyFallback(snapshot: snapshot, startedAt: startedAt,
                                         durationMs: durationMs, rawText: rawText, finalText: finalText)
        }
    }

    private func insertTextOnlyFallback(snapshot: ServingSnapshot, startedAt: Date,
                                        durationMs: Int, rawText: String, finalText: String) async {
        do {
            try await transcripts.insertTextOnly(
                profileID: snapshot.profileID, profileNameSnapshot: snapshot.profileName,
                promptSnapshot: snapshot.prompt.sourceText.isEmpty ? nil : snapshot.prompt.sourceText,
                startedAt: startedAt, durationMs: durationMs,
                modelID: snapshot.modelID, language: snapshot.language,
                rawText: rawText, finalText: finalText)
        } catch {
            Logger.app.error("text-only fallback insert failed: \(error.localizedDescription)")
        }
    }

    private func readRetentionEnabled() throws -> Bool {
        try database.read { db in
            let v = try Int.fetchOne(db, sql:
                "SELECT enabled FROM retention_policy WHERE singleton=1") ?? 0
            return v == 1
        }
    }
}
