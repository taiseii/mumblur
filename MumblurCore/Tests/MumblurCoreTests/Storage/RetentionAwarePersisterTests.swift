// MumblurCore/Tests/MumblurCoreTests/Storage/RetentionAwarePersisterTests.swift
import XCTest
import GRDB
@testable import MumblurCore

final class RetentionAwarePersisterTests: XCTestCase {

    private func tmpRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mumblur-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func wavCount(in root: URL) -> Int {
        let clips = root.appendingPathComponent("clips")
        let items = (try? FileManager.default.contentsOfDirectory(
            at: clips, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "wav" }.count
    }

    private func snapshot(profileID: String, profileName: String = "P",
                          modelID: String = "m") -> ServingSnapshot {
        ServingSnapshot(profileID: profileID, profileName: profileName, modelID: modelID,
                        language: nil, prompt: .empty, rules: [])
    }

    private func enableRetention(_ db: AppDatabase) throws {
        try db.write { conn in
            try conn.execute(sql: "UPDATE retention_policy SET enabled=1 WHERE singleton=1")
        }
    }

    func testRetentionOff_noWAV_textOnlyRow() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try AppDatabase(location: .inMemory)
        let settings = SettingsStore(database: db)
        let transcripts = TranscriptStore(database: db)
        let audio = AudioStore(root: root)
        let p = try await settings.create(name: "P", modelID: "m")
        let persister = RetentionAwarePersister(database: db, transcripts: transcripts, audio: audio)

        // retention defaults OFF (enabled=0 seeded)
        await persister.persist(samples: [0.5], snapshot: snapshot(profileID: p.id),
                                startedAt: Date(), durationMs: 1, rawText: "r", finalText: "f")

        let stats = try await transcripts.stats()
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.audioCount, 0)
        XCTAssertEqual(wavCount(in: root), 0)
    }

    func testRetentionOn_writesWAV_andRowReferencesIt() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try AppDatabase(location: .inMemory)
        let settings = SettingsStore(database: db)
        let transcripts = TranscriptStore(database: db)
        let audio = AudioStore(root: root)
        let p = try await settings.create(name: "P", modelID: "m")
        try enableRetention(db)
        let persister = RetentionAwarePersister(database: db, transcripts: transcripts, audio: audio)

        await persister.persist(samples: [0.5, 0.6, 0.7], snapshot: snapshot(profileID: p.id),
                                startedAt: Date(), durationMs: 1, rawText: "r", finalText: "f")

        let stats = try await transcripts.stats()
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.audioCount, 1)
        XCTAssertEqual(wavCount(in: root), 1)
    }

    func testInsertFailure_removesFreshlyWrittenWAV() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try AppDatabase(location: .inMemory)
        let transcripts = TranscriptStore(database: db)
        let audio = AudioStore(root: root)
        try enableRetention(db)
        let persister = RetentionAwarePersister(database: db, transcripts: transcripts, audio: audio)

        // snapshot references a profile that does NOT exist → FK violation on insertWithAudio
        await persister.persist(samples: [0.5, 0.6], snapshot: snapshot(profileID: "ghost"),
                                startedAt: Date(), durationMs: 1, rawText: "r", finalText: "f")

        let stats = try await transcripts.stats()
        XCTAssertEqual(stats.count, 0)          // insert failed
        XCTAssertEqual(wavCount(in: root), 0)   // freshly-written WAV was compensating-deleted
    }
}
