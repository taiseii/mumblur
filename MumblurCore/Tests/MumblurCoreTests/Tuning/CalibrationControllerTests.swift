// MumblurCore/Tests/MumblurCoreTests/Tuning/CalibrationControllerTests.swift
import XCTest
import GRDB
@testable import MumblurCore

private struct MappingKit: WhisperKitTranscribing {
    let outputs: [Int: String]   // keyed by Int(samples.first) == sentence index + 1
    func transcribe(audioArray: [Float], language: String?, detectLanguage: Bool,
                    promptTokens: [Int]?) async throws -> [any WhisperKitSegment] {
        let key = Int(audioArray.first ?? 0)
        struct S: WhisperKitSegment { let text: String }
        return [S(text: outputs[key] ?? "")]
    }
}

private struct ThrowingAtKit: WhisperKitTranscribing {
    let outputs: [Int: String]
    let throwAtKey: Int
    struct Boom: Error {}
    func transcribe(audioArray: [Float], language: String?, detectLanguage: Bool,
                    promptTokens: [Int]?) async throws -> [any WhisperKitSegment] {
        let key = Int(audioArray.first ?? 0)
        if key == throwAtKey { throw Boom() }
        struct S: WhisperKitSegment { let text: String }
        return [S(text: outputs[key] ?? "")]
    }
}

private actor CalPaster: Pasting {
    func paste(_ text: String) async {}
}

private struct CalPersister: DictationPersisting {
    func persist(samples: [Float], snapshot: ServingSnapshot, startedAt: Date,
                 durationMs: Int, rawText: String, finalText: String) async {}
}

final class CalibrationControllerTests: XCTestCase {

    private func tmpRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mumblur-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func script() -> CalibrationScript {
        CalibrationScript(id: "test", name: "T", language: "en", sentences: [
            .init(text: "alpha questable", role: .mining),
            .init(text: "beta questable", role: .mining),
            .init(text: "gamma questable", role: .mining),
            .init(text: "delta eval", role: .eval),
        ])
    }

    private func makeRunner(_ transcriber: Transcriber) -> Runner {
        Runner(recorder: FakeAudioRecorder(), transcriber: transcriber,
               paster: CalPaster(), persister: CalPersister(), minHoldMs: 0)
    }

    func testCeremony_suspendsRunner_recordsAndScoresAllSamples() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try AppDatabase(location: .inMemory)
        let settings = SettingsStore(database: db)
        let audio = AudioStore(root: root)
        let p = try await settings.create(name: "P", modelID: "m")
        let snapshot = ServingSnapshot(profileID: p.id, profileName: p.name, modelID: "m",
                                       language: "en", prompt: .empty, rules: [])
        let transcriber = Transcriber()
        await transcriber.commit(snapshot: snapshot, kit: MappingKit(outputs: [
            1: "alpha questionable", 2: "beta questionable",
            3: "gamma questionable", 4: "delta eval",
        ]))
        let runner = makeRunner(transcriber)
        let controller = CalibrationController(database: db, settings: settings, audio: audio,
                                               runner: runner, recorder: FakeAudioRecorder(),
                                               transcriber: transcriber)

        let runID = try await controller.run(script: script(), requestedProfile: p,
                                             expectedSnapshot: snapshot) { event in
            [Float](repeating: Float(event.index + 1), count: 16)
        }

        XCTAssertEqual(runner.setSuspendedCallsForTesting, [true, false])

        let transcribed = try db.read { conn in
            try Int.fetchOne(conn, sql:
                "SELECT COUNT(*) FROM calibration_sample WHERE run_id=? AND status='transcribed'",
                arguments: [runID]) ?? -1
        }
        XCTAssertEqual(transcribed, 4)

        let evalRaw = try db.read { conn in
            try Double.fetchOne(conn, sql:
                "SELECT eval_raw_wer FROM calibration_run WHERE id=?", arguments: [runID])
        }
        XCTAssertNotNil(evalRaw)

        let (rules, _) = try await controller.suggestions(forRun: runID)
        XCTAssertFalse(rules.isEmpty)
        XCTAssertEqual(rules.first?.pattern, "questionable")
        XCTAssertEqual(rules.first?.replacement, "questable")
    }

    func testCeremony_failedSampleRecordedAsFailed_continuesRun() async throws {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try AppDatabase(location: .inMemory)
        let settings = SettingsStore(database: db)
        let audio = AudioStore(root: root)
        let p = try await settings.create(name: "P", modelID: "m")
        let snapshot = ServingSnapshot(profileID: p.id, profileName: p.name, modelID: "m",
                                       language: "en", prompt: .empty, rules: [])
        let transcriber = Transcriber()
        // throwAtKey 3 == sentence index 2 ("gamma questable", a mining sentence)
        await transcriber.commit(snapshot: snapshot, kit: ThrowingAtKit(outputs: [
            1: "alpha questionable", 2: "beta questionable", 4: "delta eval",
        ], throwAtKey: 3))
        let runner = makeRunner(transcriber)
        let controller = CalibrationController(database: db, settings: settings, audio: audio,
                                               runner: runner, recorder: FakeAudioRecorder(),
                                               transcriber: transcriber)

        let runID = try await controller.run(script: script(), requestedProfile: p,
                                             expectedSnapshot: snapshot) { event in
            [Float](repeating: Float(event.index + 1), count: 16)
        }

        let failed = try db.read { conn in
            try Row.fetchOne(conn, sql:
                "SELECT status, error_message FROM calibration_sample WHERE run_id=? AND sample_index=2",
                arguments: [runID])
        }
        XCTAssertEqual(failed?["status"], "failed")
        let msg: String? = failed?["error_message"]
        XCTAssertNotNil(msg)

        let transcribed = try db.read { conn in
            try Int.fetchOne(conn, sql:
                "SELECT COUNT(*) FROM calibration_sample WHERE run_id=? AND status='transcribed'",
                arguments: [runID]) ?? -1
        }
        XCTAssertEqual(transcribed, 3)

        let evalRaw = try db.read { conn in
            try Double.fetchOne(conn, sql:
                "SELECT eval_raw_wer FROM calibration_run WHERE id=?", arguments: [runID])
        }
        XCTAssertNotNil(evalRaw)
    }
}
