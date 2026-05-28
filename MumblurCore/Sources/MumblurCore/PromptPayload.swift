// MumblurCore/Sources/MumblurCore/PromptPayload.swift
import Foundation

/// A tokenized prompt frozen against a specific loaded model. Created at
/// model-swap-commit time and held inside a `ServingSnapshot`; never recomputed
/// per dictation. `omittedTerms` lists vocab terms dropped to fit within the
/// token budget so the UI can show them.
public struct PromptPayload: Equatable, Sendable {
    public let sourceText: String
    public let promptTokens: [Int]
    public let omittedTerms: [String]
    public static let empty = PromptPayload(sourceText: "", promptTokens: [], omittedTerms: [])

    public init(sourceText: String, promptTokens: [Int], omittedTerms: [String]) {
        self.sourceText = sourceText; self.promptTokens = promptTokens; self.omittedTerms = omittedTerms
    }
}
