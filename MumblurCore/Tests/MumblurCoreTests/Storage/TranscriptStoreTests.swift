// MumblurCore/Tests/MumblurCoreTests/Storage/TranscriptStoreTests.swift
import XCTest
@testable import MumblurCore

final class TranscriptStoreTests: XCTestCase {

    private func setup() async throws -> (TranscriptStore, SettingsStore, Profile) {
        let db = try AppDatabase(location: .inMemory)
        let settings = SettingsStore(database: db)
        let store = TranscriptStore(database: db)
        let p = try await settings.create(name: "P", modelID: "m")
        return (store, settings, p)
    }

    func testInsert_textOnly_writesRowAndNoAudio() async throws {
        let (store, _, p) = try await setup()
        try await store.insertTextOnly(profileID: p.id, profileNameSnapshot: p.name,
            promptSnapshot: nil, startedAt: Date(), durationMs: 1234,
            modelID: "m", language: nil, rawText: "hi", finalText: "hi")
        let stats = try await store.stats()
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.audioCount, 0)
    }

    func testInsert_withAudio_requiresAllAudioFields() async throws {
        let (store, _, p) = try await setup()
        let audio = TranscriptStore.AudioMetadata(
            relPath: "clips/x.wav", bytes: 16, sha256: String(repeating: "a", count: 64),
            sampleRateHz: 16000, channels: 1, pcmEncoding: "pcm_s16le")
        try await store.insertWithAudio(profileID: p.id, profileNameSnapshot: p.name,
            promptSnapshot: nil, startedAt: Date(), durationMs: 1, modelID: "m",
            language: nil, rawText: "r", finalText: "f", audio: audio)
        let stats = try await store.stats()
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.audioCount, 1)
    }

    func testRecent_returnsReverseChronoRowsRespectingLimit() async throws {
        let (store, _, p) = try await setup()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<3 {
            try await store.insertTextOnly(profileID: p.id, profileNameSnapshot: p.name,
                promptSnapshot: nil, startedAt: base.addingTimeInterval(Double(i)),
                durationMs: i, modelID: "m", language: nil,
                rawText: "raw\(i)", finalText: "final\(i)")
        }
        let audio = TranscriptStore.AudioMetadata(
            relPath: "clips/x.wav", bytes: 4242, sha256: String(repeating: "a", count: 64),
            sampleRateHz: 16000, channels: 1, pcmEncoding: "pcm_s16le")
        try await store.insertWithAudio(profileID: p.id, profileNameSnapshot: p.name,
            promptSnapshot: "ctx", startedAt: base.addingTimeInterval(10), durationMs: 99,
            modelID: "m", language: "en", rawText: "rawA", finalText: "finalA", audio: audio)

        let rows = try await store.recent(limit: 2)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].finalText, "finalA")       // newest first
        XCTAssertEqual(rows[0].audioRelPath, "clips/x.wav")
        XCTAssertEqual(rows[0].audioBytes, 4242)
        XCTAssertEqual(rows[0].promptSnapshot, "ctx")
        XCTAssertEqual(rows[0].language, "en")
        XCTAssertEqual(rows[1].finalText, "final2")
        XCTAssertNil(rows[1].audioRelPath)
    }

    // MARK: - Corrections (training-data capture)

    private func insertOne(_ store: TranscriptStore, _ p: Profile,
        raw: String = "r", final: String = "f", withAudio: Bool = false) async throws -> Int64 {
        if withAudio {
            let audio = TranscriptStore.AudioMetadata(
                relPath: "clips/\(UUID().uuidString).wav", bytes: 16,
                sha256: String(repeating: "a", count: 64),
                sampleRateHz: 16000, channels: 1, pcmEncoding: "pcm_s16le")
            try await store.insertWithAudio(profileID: p.id, profileNameSnapshot: p.name,
                promptSnapshot: nil, startedAt: Date(), durationMs: 1, modelID: "m",
                language: "en", rawText: raw, finalText: final, audio: audio)
        } else {
            try await store.insertTextOnly(profileID: p.id, profileNameSnapshot: p.name,
                promptSnapshot: nil, startedAt: Date(), durationMs: 1, modelID: "m",
                language: "en", rawText: raw, finalText: final)
        }
        return try await store.recent(limit: 1).first!.id
    }

    func testUpsertCorrection_isLatestWins_keepsSingleRowWithNewestText() async throws {
        let (store, _, p) = try await setup()
        let tid = try await insertOne(store, p)

        try await store.upsertCorrection(transcriptID: tid, correctedText: "first")
        let early = try await store.correction(for: tid)
        try await store.upsertCorrection(transcriptID: tid, correctedText: "second", source: "manual")

        let latest = try await store.correction(for: tid)
        XCTAssertEqual(early?.correctedText, "first")
        XCTAssertEqual(latest?.correctedText, "second")        // overwrote, not appended
        XCTAssertEqual(latest?.id, early?.id)                  // same row (UNIQUE(transcript_id))
        XCTAssertGreaterThanOrEqual(latest!.updatedAt, early!.updatedAt)
    }

    func testDeleteCorrection_removesRow_leavesTranscriptIntact() async throws {
        let (store, _, p) = try await setup()
        let tid = try await insertOne(store, p)
        try await store.upsertCorrection(transcriptID: tid, correctedText: "x")

        try await store.deleteCorrection(transcriptID: tid)

        let gone = try await store.correction(for: tid)
        let transcripts = try await store.recent(limit: 10)
        XCTAssertNil(gone)                       // correction gone
        XCTAssertEqual(transcripts.count, 1)     // transcript untouched
    }

    func testCorrection_forUncorrectedTranscript_isNil() async throws {
        let (store, _, p) = try await setup()
        let tid = try await insertOne(store, p)
        let c = try await store.correction(for: tid)
        XCTAssertNil(c)
    }

    func testCorrection_cascadeDeletesWhenTranscriptSwept() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mumblur-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, p) = try await setup()
        let tid = try await insertOne(store, p)
        try await store.upsertCorrection(transcriptID: tid, correctedText: "x")

        try await store.sweep(policy: .count(limit: 0), audio: AudioStore(root: root))

        let afterSweep = try await store.correction(for: tid)
        XCTAssertNil(afterSweep)     // ON DELETE CASCADE
    }

    func testTrainingPairs_returnsRawAndCorrected_onlyForCorrectedTranscripts() async throws {
        let (store, _, p) = try await setup()
        let corrected = try await insertOne(store, p, raw: "raw text")
        _ = try await insertOne(store, p, raw: "uncorrected")   // no correction -> excluded
        try await store.upsertCorrection(transcriptID: corrected, correctedText: "clean text")

        let pairs = try await store.trainingPairs()
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].transcriptID, corrected)
        XCTAssertEqual(pairs[0].rawText, "raw text")
        XCTAssertEqual(pairs[0].correctedText, "clean text")
        XCTAssertEqual(pairs[0].language, "en")
        XCTAssertEqual(pairs[0].modelID, "m")
    }

    func testFewShotAdapter_excludesUnchangedPairs_andMapsRawToCorrected() async throws {
        let (store, _, p) = try await setup()
        let edited = try await insertOne(store, p, raw: "raw one")
        let unchanged = try await insertOne(store, p, raw: "same text")
        try await store.upsertCorrection(transcriptID: edited, correctedText: "corrected one")
        try await store.upsertCorrection(transcriptID: unchanged, correctedText: "same text") // no edit

        let adapter = TranscriptStoreFewShot(store: store)
        let examples = await adapter.examples(limit: 10)

        XCTAssertEqual(examples, [FewShotExample(raw: "raw one", corrected: "corrected one")])
    }

    func testTrainingPairs_requireAudio_excludesTextOnlyTranscripts() async throws {
        let (store, _, p) = try await setup()
        let textOnly = try await insertOne(store, p, withAudio: false)
        let withAudio = try await insertOne(store, p, withAudio: true)
        try await store.upsertCorrection(transcriptID: textOnly, correctedText: "a")
        try await store.upsertCorrection(transcriptID: withAudio, correctedText: "b")

        let all = try await store.trainingPairs(requireAudio: false)
        let audioOnly = try await store.trainingPairs(requireAudio: true)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(audioOnly.count, 1)
        XCTAssertEqual(audioOnly[0].transcriptID, withAudio)
        XCTAssertNotNil(audioOnly[0].audioRelPath)
    }
}
