// MumblurCore/Sources/MumblurCore/PromptBuilder.swift
import Foundation

public protocol Tokenizing: Sendable {
    func encode(text: String) throws -> [Int]
}

public enum PromptBudget: Sendable { case max; case tokens(Int) }

public typealias TokenizeText = @Sendable (String) throws -> [Int]

public enum PromptBuilder {
    /// Builds a `PromptPayload` deterministically:
    ///   * `initialPrompt` (if any) is the first sentence;
    ///   * vocab terms follow as "Glossary: term1, term2, …";
    ///   * tokens are truncated to `budget`, dropping trailing vocab terms;
    ///   * `omittedTerms` is reported back in original order.
    public static func build(initialPrompt: String?,
                             vocab: [String],
                             budget: PromptBudget,
                             tokenize: TokenizeText) throws -> PromptPayload {
        let hasPrompt = !(initialPrompt ?? "").isEmpty
        if !hasPrompt && vocab.isEmpty { return .empty }

        func compose(_ kept: [String]) -> String {
            var s = ""
            if let p = initialPrompt, !p.isEmpty { s += p }
            if !kept.isEmpty {
                if !s.isEmpty { s += " " }
                s += "Glossary: " + kept.joined(separator: ", ")
            }
            return s
        }

        var kept = vocab
        var source = compose(kept)
        var tokens = try tokenize(source)
        var omitted: [String] = []

        if case .tokens(let limit) = budget {
            while tokens.count > limit, let dropped = kept.popLast() {
                omitted.append(dropped)
                source = compose(kept)
                tokens = try tokenize(source)
            }
            if tokens.count > limit { tokens = Array(tokens.prefix(limit)) }
        }
        return PromptPayload(sourceText: source,
                             promptTokens: tokens,
                             omittedTerms: omitted.reversed())
    }
}
