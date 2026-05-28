// MumblurCore/Tests/MumblurCoreTests/Storage/AudioStoreTests.swift
import XCTest
@testable import MumblurCore

final class AudioStoreTests: XCTestCase {

    private func tmpRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mumblur-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testWriteThenMove_producesValidWAV_andStableSha256() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = AudioStore(root: root)
        let samples: [Float] = Array(repeating: 0.5, count: 1600) // 0.1s
        let result = try await audio.write(samples: samples, sampleRateHz: 16000)
        XCTAssertEqual(result.sha256.count, 64)
        XCTAssertGreaterThan(result.bytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.absoluteURL.path))
        XCTAssertTrue(result.relPath.hasPrefix("clips/"))
        XCTAssertTrue(result.relPath.hasSuffix(".wav"))
    }

    func testOrphanCleanup_deletesUnreferencedWAVs_keepsReferenced() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try AppDatabase(location: .inMemory)
        let settings = SettingsStore(database: db)
        let transcripts = TranscriptStore(database: db)
        let audio = AudioStore(root: root)
        let p = try await settings.create(name: "P", modelID: "m")

        let keep = try await audio.write(samples: [0.1, 0.2], sampleRateHz: 16000)
        let drop = try await audio.write(samples: [0.3, 0.4], sampleRateHz: 16000)
        try await transcripts.insertWithAudio(
            profileID: p.id, profileNameSnapshot: p.name, promptSnapshot: nil,
            startedAt: Date(), durationMs: 1, modelID: "m", language: nil,
            rawText: "r", finalText: "f",
            audio: .init(relPath: keep.relPath, bytes: keep.bytes, sha256: keep.sha256,
                         sampleRateHz: 16000, channels: 1, pcmEncoding: "pcm_s16le"))

        try await audio.cleanupOrphans(referencedRelPaths: { try await transcripts.allAudioRelPaths() })
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.absoluteURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: drop.absoluteURL.path))
    }

    func testRetentionSweeper_byCount_keepsNewest() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try AppDatabase(location: .inMemory)
        let settings = SettingsStore(database: db)
        let transcripts = TranscriptStore(database: db)
        let audio = AudioStore(root: root)
        let p = try await settings.create(name: "P", modelID: "m")

        for i in 0..<5 {
            let r = try await audio.write(samples: [0.0], sampleRateHz: 16000)
            try await transcripts.insertWithAudio(
                profileID: p.id, profileNameSnapshot: p.name, promptSnapshot: nil,
                startedAt: Date(timeIntervalSince1970: Double(i)), durationMs: 1,
                modelID: "m", language: nil, rawText: "r", finalText: "f",
                audio: .init(relPath: r.relPath, bytes: r.bytes, sha256: r.sha256,
                             sampleRateHz: 16000, channels: 1, pcmEncoding: "pcm_s16le"))
        }
        try await transcripts.sweep(policy: .count(limit: 2), audio: audio)
        let stats = try await transcripts.stats()
        XCTAssertEqual(stats.count, 2)
    }
}
