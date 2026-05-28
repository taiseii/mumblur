// MumblurCore/Sources/MumblurCore/TranscriptPostProcessor.swift
import Foundation
import os

public struct TranscriptPostProcessor: Sendable {
    public init() {}

    public func apply(_ text: String, rules: [ReplacementRule]) -> String {
        var out = text
        // Lower sort_order runs first; deterministic id tiebreaker.
        let ordered = rules.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
        for rule in ordered {
            out = applyOne(rule, to: out)
        }
        return out
    }

    private func applyOne(_ rule: ReplacementRule, to text: String) -> String {
        var options: NSRegularExpression.Options = []
        if !rule.caseSensitive { options.insert(.caseInsensitive) }
        let pattern: String
        if rule.isRegex {
            pattern = rule.pattern
        } else {
            let escaped = NSRegularExpression.escapedPattern(for: rule.pattern)
            pattern = rule.wordBoundary ? "\\b\(escaped)\\b" : escaped
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            Logger.app.error("skipping invalid regex rule id=\(String(rule.id), privacy: .public)")
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range,
                                              withTemplate: rule.replacement)
    }
}
