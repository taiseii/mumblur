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
func loadWavFloatMono16kHz(url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    // WAV header is 44 bytes; data is signed 16-bit LE PCM mono after that.
    guard data.count > 44 else { return [] }
    let pcm = data.subdata(in: 44..<data.count)
    var out = [Float](repeating: 0, count: pcm.count / 2)
    pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let ptr = raw.bindMemory(to: Int16.self)
        for i in 0..<out.count {
            out[i] = Float(ptr[i]) / 32768.0
        }
    }
    return out
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
