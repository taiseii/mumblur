import XCTest
@testable import MumblurCore

final class TranscriberTests: XCTestCase {
    func testTranscribe_joinsSegmentsAndTrims() async throws {
        let fake = FakeWhisperKit()
        fake.nextSegments = [
            FakeWhisperKit.Segment(text: "  hello "),
            FakeWhisperKit.Segment(text: "world  "),
        ]
        let t = Transcriber(kit: fake, language: nil)
        let result = try await t.transcribe([0.0, 0.1, 0.2])
        XCTAssertEqual(result, "hello world")
        XCTAssertEqual(fake.transcribeCalls.count, 1)
    }

    func testTranscribe_emptySamplesReturnsEmpty() async throws {
        let fake = FakeWhisperKit()
        let t = Transcriber(kit: fake, language: nil)
        let result = try await t.transcribe([])
        XCTAssertEqual(result, "")
        XCTAssertEqual(fake.transcribeCalls.count, 0)
    }

    func testTranscribe_languageNilEnablesDetectLanguage() async throws {
        let fake = FakeWhisperKit()
        let t = Transcriber(kit: fake, language: nil)
        _ = try await t.transcribe([0.1])
        XCTAssertEqual(fake.lastLanguage, nil)
        XCTAssertEqual(fake.lastDetectLanguage, true)
    }

    func testTranscribe_languageSetDisablesAutoDetect() async throws {
        let fake = FakeWhisperKit()
        let t = Transcriber(kit: fake, language: "en")
        _ = try await t.transcribe([0.1])
        XCTAssertEqual(fake.lastLanguage, "en")
        XCTAssertEqual(fake.lastDetectLanguage, false)
    }

    /// Slow: loads the real WhisperKit model. Skipped unless MUMBLUR_RUN_SLOW=1.
    func testIntegration_transcribesHelloWorldFixture() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MUMBLUR_RUN_SLOW"] == "1",
            "Slow integration test (set MUMBLUR_RUN_SLOW=1 to enable)"
        )
        let url = Bundle.module.url(forResource: "hello_world", withExtension: "wav",
                                    subdirectory: "Fixtures")
        guard let url else {
            XCTFail("missing hello_world.wav fixture")
            return
        }
        let samples = try loadWavFloatMono16kHz(url: url)
        let kit = try await RealWhisperKit.make()
        let t = Transcriber(kit: kit, language: nil)
        let result = try await t.transcribe(samples).lowercased()
        XCTAssertTrue(result.contains("hello") && result.contains("world"),
                      "got: \(result)")
    }
}

/// Helper exposed for tests. Loads a 16 kHz mono PCM WAV into [Float].
/// Walks RIFF chunks to find `data` — `afconvert` can emit a `FLLR` padding
/// chunk before `data`, so the legacy 44-byte header assumption is wrong.
func loadWavFloatMono16kHz(url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count >= 12,
          data.subdata(in: 0..<4) == Data("RIFF".utf8),
          data.subdata(in: 8..<12) == Data("WAVE".utf8)
    else { return [] }

    var i = 12
    while i + 8 <= data.count {
        let id = data.subdata(in: i..<(i + 4))
        let size = data.subdata(in: (i + 4)..<(i + 8)).withUnsafeBytes { raw in
            raw.load(as: UInt32.self).littleEndian
        }
        let payloadStart = i + 8
        let payloadEnd = payloadStart + Int(size)
        if id == Data("data".utf8) {
            guard payloadEnd <= data.count else { return [] }
            let pcm = data.subdata(in: payloadStart..<payloadEnd)
            var out = [Float](repeating: 0, count: pcm.count / 2)
            pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let ptr = raw.bindMemory(to: Int16.self)
                for i in 0..<out.count {
                    out[i] = Float(ptr[i]) / 32768.0
                }
            }
            return out
        }
        i = payloadEnd + (Int(size) & 1) // RIFF chunks are word-aligned
    }
    return []
}

/// Fake conforming to WhisperKitTranscribing.
final class FakeWhisperKit: WhisperKitTranscribing, @unchecked Sendable {
    struct Segment: WhisperKitSegment { var text: String }

    var nextSegments: [Segment] = []
    var transcribeCalls: [[Float]] = []
    var lastLanguage: String? = nil
    var lastDetectLanguage: Bool? = nil

    func transcribe(audioArray: [Float],
                    language: String?,
                    detectLanguage: Bool) async throws -> [any WhisperKitSegment] {
        transcribeCalls.append(audioArray)
        lastLanguage = language
        lastDetectLanguage = detectLanguage
        return nextSegments
    }
}
