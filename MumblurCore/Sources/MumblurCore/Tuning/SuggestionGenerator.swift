// MumblurCore/Sources/MumblurCore/Tuning/SuggestionGenerator.swift
import Foundation

public struct SuggestionGenerator: Sendable {
    public let minSupport: Int
    public let minPrecision: Double

    public init(minSupport: Int = 3, minPrecision: Double = 0.8) {
        self.minSupport = minSupport; self.minPrecision = minPrecision
    }

    public struct RuleSuggestion: Equatable, Sendable {
        public let pattern: String
        public let replacement: String
        public let isRegex = false
        public let caseSensitive = false
        public let wordBoundary = true
    }

    public func generateRules(from subs: [ErrorMiner.Substitution]) -> [RuleSuggestion] {
        subs.compactMap { s in
            guard s.count >= minSupport else { return nil }
            let precision = 1.0 / Double(s.distinctExpected)
            guard precision >= minPrecision else { return nil }
            return RuleSuggestion(pattern: s.produced, replacement: s.expected)
        }
    }

    public func generateVocab(from subs: [ErrorMiner.Substitution]) -> [String] {
        Array(Set(subs.filter { $0.count >= minSupport && $0.produced != $0.expected }
                  .map(\.expected))).sorted()
    }
}
