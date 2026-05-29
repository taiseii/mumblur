// MumblurCore/Sources/MumblurCore/FewShot.swift
import Foundation
import os

/// One `(raw transcription -> user's intended text)` example, used to steer the LLM editor.
public struct FewShotExample: Sendable, Equatable {
    public let raw: String
    public let corrected: String
    public init(raw: String, corrected: String) {
        self.raw = raw
        self.corrected = corrected
    }
}

/// Supplies recent correction examples for prompt augmentation. Best-effort: implementations
/// return `[]` rather than throwing, so a missing source never blocks editing.
public protocol FewShotProviding: Sendable {
    func examples(limit: Int) async -> [FewShotExample]
}

/// No examples — the default, leaving the editor prompt untouched.
public struct NoOpFewShot: FewShotProviding {
    public init() {}
    public func examples(limit: Int) async -> [FewShotExample] { [] }
}

/// Folds correction examples into the base editor instructions (v1: system-prompt stuffing).
/// A future move to alternating user/assistant messages would replace the call site, not this type.
public enum FewShotPrompt {
    public static func augment(base: String, examples: [FewShotExample]) -> String {
        guard !examples.isEmpty else { return base }
        var s = base
        s += "\n\nHere are examples of how to edit this user's transcripts (raw -> corrected):"
        for e in examples {
            s += "\n\nRaw: \(e.raw)\nCorrected: \(e.corrected)"
        }
        return s
    }
}

/// Pulls examples from saved corrections. Excludes pairs the user left unchanged
/// (raw == corrected) since they teach nothing about what to edit and waste prompt budget.
public struct TranscriptStoreFewShot: FewShotProviding {
    private let store: TranscriptStore
    public init(store: TranscriptStore) { self.store = store }

    public func examples(limit: Int) async -> [FewShotExample] {
        do {
            let pairs = try await store.trainingPairs(limit: limit, requireAudio: false)
            return pairs
                .filter { $0.rawText != $0.correctedText }
                .map { FewShotExample(raw: $0.rawText, corrected: $0.correctedText) }
        } catch {
            Logger.app.error("few-shot example fetch failed: \(error.localizedDescription)")
            return []
        }
    }
}
