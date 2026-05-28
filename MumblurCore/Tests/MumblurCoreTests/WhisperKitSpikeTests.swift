// MumblurCore/Tests/MumblurCoreTests/WhisperKitSpikeTests.swift
import XCTest
@testable import MumblurCore
import WhisperKit

/// Slow integration spike. Confirms: (1) load works for the tiny model;
/// (2) the tokenizer is reachable and encode(text:) produces tokens;
/// (3) WhisperKit accepts DecodingOptions(promptTokens:) and a transcribe call
/// with non-nil prompt tokens completes without throwing. We do NOT assert text
/// content — tiny models aren't deterministic on biasing. Wiring smoke check only.
final class WhisperKitSpikeTests: XCTestCase {

    private var slow: Bool { ProcessInfo.processInfo.environment["MUMBLUR_RUN_SLOW"] == "1" }

    func testPipelineLoadsAndAcceptsPromptTokens() async throws {
        try XCTSkipUnless(slow, "set MUMBLUR_RUN_SLOW=1 to run this spike")
        let kit = try await RealWhisperKit.make(modelHint: "openai_whisper-tiny")

        // (2) tokenizer reachable.
        let tokens = try kit.encode(text: "Mumblur Questable")
        XCTAssertFalse(tokens.isEmpty, "tokenizer.encode produced no tokens")

        // (3) transcribe with promptTokens completes without throwing.
        let chunk = 16_000 * 30
        let silence = [Float](repeating: 0, count: chunk)
        let options = DecodingOptions(language: "en",
                                      detectLanguage: false,
                                      promptTokens: tokens)
        _ = try await kit.whisperPipeline.transcribe(audioArray: silence, decodeOptions: options)
    }
}
