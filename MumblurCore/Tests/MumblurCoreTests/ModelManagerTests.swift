// MumblurCore/Tests/MumblurCoreTests/ModelManagerTests.swift
import XCTest
@testable import MumblurCore

/// A loader whose load duration is controllable per modelID so we can interleave
/// a slow older swap with a fast newer one.
private actor ControllableLoader: ModelLoading {
    var schedule: [String: UInt64] = [:]   // modelID → ns delay
    var calls: [String] = []
    func setDelay(modelID: String, ns: UInt64) { schedule[modelID] = ns }
    func load(modelID: String) async throws -> LoadedModel {
        calls.append(modelID)
        if let ns = schedule[modelID] { try await Task.sleep(nanoseconds: ns) }
        return LoadedModel(kit: FixedKit(text: modelID, tag: modelID), tokenizer: FakeTokenizer())
    }
}

private struct FixedKit: WhisperKitTranscribing {
    let text: String; let tag: String
    func transcribe(audioArray: [Float], language: String?, detectLanguage: Bool,
                    promptTokens: [Int]?) async throws -> [any WhisperKitSegment] {
        struct S: WhisperKitSegment { let text: String }
        return [S(text: text)]
    }
}

private struct FakeTokenizer: Tokenizing {
    func encode(text: String) throws -> [Int] { Array(0..<text.count) }
}

private struct FailingLoader: ModelLoading {
    struct Boom: Error {}
    func load(modelID: String) async throws -> LoadedModel { throw Boom() }
}

final class ModelManagerTests: XCTestCase {

    private func profile(name: String, modelID: String) -> Profile {
        Profile(id: "id-\(name)", name: name, language: nil, modelID: modelID,
                initialPrompt: nil, vocab: [], rules: [],
                createdAt: Date(), updatedAt: Date(), deletedAt: nil)
    }

    func testSwap_commitsServingSnapshotOnTranscriber() async throws {
        let loader = ControllableLoader()
        let transcriber = Transcriber()
        let manager = ModelManager(loader: loader, transcriber: transcriber)
        let snap = try await manager.requestSwap(to: profile(name: "A", modelID: "m1"))
        XCTAssertEqual(snap.modelID, "m1")
        let out = try await transcriber.transcribe([0])
        XCTAssertEqual(out.snapshot.modelID, "m1")
    }

    func testOlderSlowSwap_throwsStaleSwap_doesNotClobberNewerCommit() async throws {
        let loader = ControllableLoader()
        await loader.setDelay(modelID: "old", ns: 200_000_000)  // 200 ms
        await loader.setDelay(modelID: "new", ns: 10_000_000)   // 10 ms
        let transcriber = Transcriber()
        let manager = ModelManager(loader: loader, transcriber: transcriber)

        let oldProfile = profile(name: "Old", modelID: "old")
        let newProfile = profile(name: "New", modelID: "new")
        async let oldResult = throwingResult { try await manager.requestSwap(to: oldProfile) }
        try await Task.sleep(nanoseconds: 5_000_000)            // 5 ms
        async let newResult = throwingResult { try await manager.requestSwap(to: newProfile) }

        let oldFinished = await oldResult
        let newFinished = await newResult
        // The newer swap committed.
        XCTAssertNoThrow(try newFinished.get())
        XCTAssertEqual((try? newFinished.get())?.modelID, "new")
        // The older one was superseded.
        switch oldFinished {
        case .failure(let e as ModelManagerError):
            XCTAssertEqual(e, .staleSwap)
        default:
            XCTFail("expected .staleSwap from the older request, got \(oldFinished)")
        }

        let out = try await transcriber.transcribe([0])
        XCTAssertEqual(out.snapshot.modelID, "new")
    }

    func testLoaderError_surfacesAsRequestSwapThrow() async {
        let manager = ModelManager(loader: FailingLoader(), transcriber: Transcriber())
        do {
            _ = try await manager.requestSwap(to: profile(name: "X", modelID: "bad"))
            XCTFail("expected the loader error to surface")
        } catch is ModelManagerError {
            XCTFail("loader's own error should surface, not ModelManagerError")
        } catch is FailingLoader.Boom {
            // expected
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

private func throwingResult<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

// MARK: - LLMEdit tests

private struct FakeLLMTokenizer: Tokenizing { func encode(text: String) throws -> [Int] { [] } }
private struct FakeLLMKit: WhisperKitTranscribing {
    func transcribe(audioArray: [Float], language: String?, detectLanguage: Bool,
                    promptTokens: [Int]?) async throws -> [any WhisperKitSegment] { [] }
}
private struct FakeLLMLoader: ModelLoading {
    func load(modelID: String) async throws -> LoadedModel {
        LoadedModel(kit: FakeLLMKit(), tokenizer: FakeLLMTokenizer())
    }
}

final class ModelManagerLLMEditTests: XCTestCase {
    private func profile(enabled: Bool, prompt: String?) -> Profile {
        Profile(id: "p", name: "P", language: nil, modelID: "m",
                initialPrompt: nil, vocab: [], rules: [],
                llmEditEnabled: enabled, llmEditPrompt: prompt,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0), deletedAt: nil)
    }

    func testSnapshot_resolvesEnabledAndDefaultPrompt() async throws {
        let mgr = ModelManager(loader: FakeLLMLoader(), transcriber: Transcriber())
        let snapNilPrompt = try await mgr.requestSwap(to: profile(enabled: true, prompt: nil))
        XCTAssertTrue(snapNilPrompt.llmEdit.enabled)
        XCTAssertEqual(snapNilPrompt.llmEdit.prompt, LLMEditConfig.defaultPrompt)

        let snapBlank = try await mgr.requestSwap(to: profile(enabled: true, prompt: "   "))
        XCTAssertEqual(snapBlank.llmEdit.prompt, LLMEditConfig.defaultPrompt)

        let snapCustom = try await mgr.requestSwap(to: profile(enabled: true, prompt: "Custom"))
        XCTAssertEqual(snapCustom.llmEdit.prompt, "Custom")

        let snapOff = try await mgr.requestSwap(to: profile(enabled: false, prompt: "x"))
        XCTAssertFalse(snapOff.llmEdit.enabled)
    }
}
