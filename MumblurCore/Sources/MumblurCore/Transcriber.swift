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
                    detectLanguage: Bool) async throws -> [any WhisperKitSegment]
}

public protocol Transcribing: Sendable {
    func transcribe(_ samples: [Float]) async throws -> String
}

public actor Transcriber: Transcribing {
    private let kit: any WhisperKitTranscribing
    private let language: String?

    public init(kit: any WhisperKitTranscribing, language: String?) {
        self.kit = kit
        self.language = language
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { return "" }
        let detect = (language == nil)
        let segments = try await kit.transcribe(
            audioArray: samples,
            language: language,
            detectLanguage: detect
        )
        let joined = segments.map(\.text).joined()
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Concrete WhisperKit-backed implementation. Constructed via async factory.
public final class RealWhisperKit: WhisperKitTranscribing, @unchecked Sendable {
    private let pipeline: WhisperKit

    private init(pipeline: WhisperKit) {
        self.pipeline = pipeline
    }

    public static func make(modelHint: String? = nil) async throws -> RealWhisperKit {
        let resolved = try await resolveModelName(preferred: modelHint)
        Logger.transcribe.info("loading WhisperKit model: \(resolved, privacy: .public)")
        let pipeline = try await WhisperKit(WhisperKitConfig(model: resolved))
        return RealWhisperKit(pipeline: pipeline)
    }

    private static func resolveModelName(preferred: String?) async throws -> String {
        let available = try await WhisperKit.fetchAvailableModels()
        if let preferred, available.contains(preferred) { return preferred }
        // Prefer a turbo variant by name substring; fall back to the largest large-v3.
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

    public func transcribe(audioArray: [Float],
                           language: String?,
                           detectLanguage: Bool) async throws -> [any WhisperKitSegment] {
        let options = DecodingOptions(
            language: language,
            usePrefillPrompt: true,
            detectLanguage: detectLanguage
        )
        let results = try await pipeline.transcribe(audioArray: audioArray,
                                                    decodeOptions: options)
        // `results` is [TranscriptionResult]; flatten its segments.
        return results.flatMap { result in
            result.segments.map { Segment(text: $0.text) }
        }
    }

    private struct Segment: WhisperKitSegment {
        let text: String
    }
}
