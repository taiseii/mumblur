// MumblurCore/Sources/MumblurCore/Tuning/ErrorMiner.swift
import Foundation

public struct ErrorMiner: Sendable {
    public struct Sample: Sendable {
        public let groundTruth: String
        public let raw: String
        public init(groundTruth: String, raw: String) {
            self.groundTruth = groundTruth; self.raw = raw
        }
    }

    public struct Substitution: Equatable, Sendable {
        public let produced: String       // what Whisper said
        public let expected: String       // what the script said
        public let count: Int
        public let distinctExpected: Int  // how many distinct expected forms share this produced form
    }

    private let normalizer: WERNormalizer
    public init(normalizer: WERNormalizer = WERNormalizer()) { self.normalizer = normalizer }

    public func mineSubstitutions(samples: [Sample]) -> [Substitution] {
        var tally: [String: [String: Int]] = [:]
        for s in samples {
            let expectedTokens = normalizer.tokens(s.groundTruth)
            let producedTokens = normalizer.tokens(s.raw)
            let aligned = alignByLCS(expectedTokens, producedTokens)
            for (exp, prod) in aligned where exp != nil && prod != nil && exp != prod {
                tally[prod!, default: [:]][exp!, default: 0] += 1
            }
        }
        return tally.map { (produced, expectedCounts) in
            let total = expectedCounts.values.reduce(0, +)
            return Substitution(produced: produced,
                                expected: expectedCounts.max(by: { $0.value < $1.value })!.key,
                                count: total,
                                distinctExpected: expectedCounts.count)
        }
    }

    /// LCS-based alignment that emits pairs (expected, produced).
    private func alignByLCS(_ expected: [String], _ produced: [String])
        -> [(String?, String?)] {
        let n = expected.count, m = produced.count
        if n == 0 || m == 0 {
            return (0..<max(n, m)).map { i in
                (i < n ? expected[i] : nil, i < m ? produced[i] : nil)
            }
        }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                dp[i][j] = expected[i - 1] == produced[j - 1]
                    ? dp[i - 1][j - 1] + 1
                    : max(dp[i - 1][j], dp[i][j - 1])
            }
        }
        var pairs: [(String?, String?)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            if expected[i - 1] == produced[j - 1] {
                pairs.append((expected[i - 1], produced[j - 1])); i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                pairs.append((expected[i - 1], nil)); i -= 1
            } else {
                pairs.append((nil, produced[j - 1])); j -= 1
            }
        }
        while i > 0 { pairs.append((expected[i - 1], nil)); i -= 1 }
        while j > 0 { pairs.append((nil, produced[j - 1])); j -= 1 }
        let raw = Array(pairs.reversed())
        var out: [(String?, String?)] = []
        var k = 0
        while k < raw.count {
            if k + 1 < raw.count,
               case let (e?, nil) = raw[k],
               case let (nil, p?) = raw[k + 1] {
                out.append((e, p)); k += 2
            } else if k + 1 < raw.count,
                      case let (nil, p?) = raw[k],
                      case let (e?, nil) = raw[k + 1] {
                out.append((e, p)); k += 2
            } else {
                out.append(raw[k]); k += 1
            }
        }
        return out
    }
}
