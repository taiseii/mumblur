import Foundation
import WhisperKit
import os

public protocol WhisperKitSegment: Sendable {
    var text: String { get }
}

/// Thin abstraction over WhisperKit so it can be faked. The real implementation
/// lives in `RealWhisperKit` below.
public protocol WhisperKitTranscribing: Sendable {
    func transcribe(audioArray: [Float],
                    language: String?,
                    detectLanguage: Bool,
                    promptTokens: [Int]?) async throws -> [any WhisperKitSegment]
}


public struct TranscriptionOutput: Sendable {
    public let rawText: String
    public let snapshot: ServingSnapshot
    public init(rawText: String, snapshot: ServingSnapshot) {
        self.rawText = rawText
        self.snapshot = snapshot
    }
}

public enum TranscriberError: Error { case notServing }

public actor Transcriber {
    private var serving: ServingSnapshot?
    private var kit: (any WhisperKitTranscribing)?

    public init() {}

    /// Atomically replace the active serving snapshot + pipeline.
    public func commit(snapshot: ServingSnapshot, kit: any WhisperKitTranscribing) {
        self.serving = snapshot
        self.kit = kit
    }

    public func transcribe(_ samples: [Float]) async throws -> TranscriptionOutput {
        guard let snap = serving, let kit else { throw TranscriberError.notServing }
        guard !samples.isEmpty else {
            return TranscriptionOutput(rawText: "", snapshot: snap)
        }
        let detect = (snap.language == nil)
        let prompt = snap.prompt.promptTokens.isEmpty ? nil : snap.prompt.promptTokens
        let segments = try await kit.transcribe(audioArray: samples,
                                                language: snap.language,
                                                detectLanguage: detect,
                                                promptTokens: prompt)
        let raw = segments.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionOutput(rawText: raw, snapshot: snap)
    }
}

/// Concrete WhisperKit-backed implementation. Constructed via async factory.
public final class RealWhisperKit: WhisperKitTranscribing, @unchecked Sendable {
    private let pipeline: WhisperKit

    private init(pipeline: WhisperKit) {
        self.pipeline = pipeline
    }

    /// Public wrapper so the App target (which imports MumblurCore, not WhisperKit) can list models.
    public static func fetchAvailableModels() async throws -> [String] {
        try await WhisperKit.fetchAvailableModels()
    }

    public static func make(modelHint: String? = nil) async throws -> RealWhisperKit {
        let resolved = try await resolveModelName(preferred: modelHint)
        Logger.transcribe.info("loading WhisperKit model: \(resolved, privacy: .public)")
        let pipeline = try await WhisperKit(WhisperKitConfig(model: resolved, load: true))
        return RealWhisperKit(pipeline: pipeline)
    }

    private static func resolveModelName(preferred: String?) async throws -> String {
        let available = try await WhisperKit.fetchAvailableModels()
        if let preferred, available.contains(preferred) { return preferred }
        // Prefer openai_whisper turbo (multilingual) over distil-whisper turbo (en-only).
        if let openaiTurbo = available.first(where: {
            $0.lowercased().contains("turbo") && !$0.lowercased().contains("distil")
        }) {
            return openaiTurbo
        }
        if let turbo = available.first(where: { $0.lowercased().contains("turbo") }) {
            return turbo
        }
        if let largeV3 = available.first(where: { $0.lowercased().contains("large-v3") }) {
            Logger.transcribe.warning("no turbo variant found; falling back to \(largeV3, privacy: .public)")
            return largeV3
        }
        throw NSError(
            domain: "MumblurCore.Transcriber",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no suitable WhisperKit model found"]
        )
    }

    /// Internal accessor for tests and the integration spike.
    internal var whisperPipeline: WhisperKit { pipeline }

    /// Encode `text` into Whisper token IDs using the loaded model's tokenizer.
    /// Returns an empty array if the tokenizer is not yet loaded.
    /// Throws to satisfy the `Tokenizing` protocol shape used by the rest of the pipeline.
    public func encode(text: String) throws -> [Int] {
        guard let t = pipeline.tokenizer else { return [] }
        return t.encode(text: text)
    }

    /// Whisper operates on 30s chunks; WhisperKit does NOT auto-pad short audio,
    /// so we pad here. Also, `TranscriptionSegment.text` includes special tokens
    /// (e.g. `<|startoftranscript|>`) — we use the cleaned `result.text` instead.
    /// `promptTokens` biases decoding; empty/nil means no biasing.
    public func transcribe(audioArray: [Float],
                           language: String?,
                           detectLanguage: Bool,
                           promptTokens: [Int]?) async throws -> [any WhisperKitSegment] {
        let chunk = 16_000 * 30
        let padded: [Float]
        if audioArray.count < chunk {
            padded = audioArray + [Float](repeating: 0, count: chunk - audioArray.count)
        } else {
            padded = audioArray
        }
        let options = DecodingOptions(
            language: language,
            detectLanguage: detectLanguage,
            promptTokens: (promptTokens?.isEmpty == true) ? nil : promptTokens
        )
        let results = try await pipeline.transcribe(audioArray: padded,
                                                    decodeOptions: options)
        return results.compactMap { result -> (any WhisperKitSegment)? in
            let clean = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : Segment(text: clean)
        }
    }

    private struct Segment: WhisperKitSegment {
        let text: String
    }
}
