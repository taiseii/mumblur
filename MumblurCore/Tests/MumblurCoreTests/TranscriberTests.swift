// MumblurCore/Tests/MumblurCoreTests/TranscriberTests.swift
import XCTest
@testable import MumblurCore

private struct FakeKit: WhisperKitTranscribing {
    let output: String
    var observedPromptTokens: [Int]? = nil  // captured for assertions
    func transcribe(audioArray: [Float], language: String?, detectLanguage: Bool,
                    promptTokens: [Int]?) async throws -> [any WhisperKitSegment] {
        struct S: WhisperKitSegment { let text: String }
        return output.isEmpty ? [] : [S(text: output)]
    }
}

/// Reference-typed spy variant so a test can read back the prompt tokens passed
/// to the most recent `transcribe(...)` call.
private final class SpyKit: WhisperKitTranscribing, @unchecked Sendable {
    let output: String
    private(set) var lastPromptTokens: [Int]?
    init(output: String) { self.output = output }
    func transcribe(audioArray: [Float], language: String?, detectLanguage: Bool,
                    promptTokens: [Int]?) async throws -> [any WhisperKitSegment] {
        lastPromptTokens = promptTokens
        struct S: WhisperKitSegment { let text: String }
        return output.isEmpty ? [] : [S(text: output)]
    }
}

final class TranscriberTests: XCTestCase {

    private func snap(profile: String = "p", model: String = "m",
                      language: String? = nil,
                      prompt: PromptPayload = .empty,
                      rules: [ReplacementRule] = []) -> ServingSnapshot {
        ServingSnapshot(profileID: "id-\(profile)", profileName: profile, modelID: model,
                        language: language, prompt: prompt, rules: rules)
    }

    func testTranscribe_returnsRawAndSnapshot() async throws {
        let t = Transcriber()
        await t.commit(snapshot: snap(), kit: FakeKit(output: " hello "))
        let result = try await t.transcribe([1, 2, 3])
        XCTAssertEqual(result.rawText, "hello")
        XCTAssertEqual(result.snapshot.profileName, "p")
    }

    func testCommitSwap_replacesServing() async throws {
        let t = Transcriber()
        await t.commit(snapshot: snap(profile: "a"), kit: FakeKit(output: "x"))
        await t.commit(snapshot: snap(profile: "b"), kit: FakeKit(output: "y"))
        let result = try await t.transcribe([0])
        XCTAssertEqual(result.snapshot.profileName, "b")
        XCTAssertEqual(result.rawText, "y")
    }

    func testTranscribe_beforeCommit_throws() async {
        let t = Transcriber()
        do {
            _ = try await t.transcribe([0])
            XCTFail("expected NotServingError")
        } catch {}
    }

    func testTranscribe_threadsPromptTokensFromSnapshot() async throws {
        let t = Transcriber()
        let spy = SpyKit(output: "ok")
        let payload = PromptPayload(sourceText: "Glossary: Questable",
                                    promptTokens: [42, 7, 9], omittedTerms: [])
        await t.commit(snapshot: snap(prompt: payload), kit: spy)
        _ = try await t.transcribe([1, 2, 3])
        XCTAssertEqual(spy.lastPromptTokens, [42, 7, 9])
    }
}
