// MumblurCore/Sources/MumblurCore/Tuning/WERCalculator.swift
import Foundation

public struct WERCalculator: Sendable {
    public static let scoringVersion = "wer_v1"
    private let normalizer: WERNormalizer
    public init(normalizer: WERNormalizer = WERNormalizer()) { self.normalizer = normalizer }

    public func wer(reference: String, hypothesis: String) -> Double {
        let ref = normalizer.tokens(reference)
        let hyp = normalizer.tokens(hypothesis)
        if ref.isEmpty { return hyp.isEmpty ? 0.0 : 1.0 }
        return Double(levenshtein(ref, hyp)) / Double(ref.count)
    }

    /// Token-level Levenshtein distance with substitution cost 1.
    private func levenshtein(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,            // deletion
                    curr[j - 1] + 1,        // insertion
                    prev[j - 1] + cost      // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
