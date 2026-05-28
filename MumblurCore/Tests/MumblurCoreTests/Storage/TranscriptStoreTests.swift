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
}
