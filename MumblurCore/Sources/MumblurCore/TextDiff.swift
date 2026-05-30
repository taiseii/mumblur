// MumblurCore/Sources/MumblurCore/TextDiff.swift
//
// Pure, UI-agnostic text comparison. Used by the Data tab to highlight what
// the LLM-edit + replacement-rule stages actually changed, so the user can
// see the cleanup at a glance instead of comparing two near-identical paragraphs.
//
// Word-level diff (not character-level): a single inserted "the" is a more
// useful signal than three inserted letters t/h/e. Uses the standard LCS
// dynamic-programming algorithm — O(n*m) time and memory in word counts.
// Transcripts cap at a few hundred words, so this is fine for interactive use.

import Foundation

public enum TextDiff {
    /// One contiguous run in the diff result.
    public enum Span: Equatable, Sendable {
        case equal(String)
        case added(String)
        case removed(String)
    }

    /// Numbers for the section header — "430 chars (−20)" style summary.
    public struct Summary: Equatable, Sendable {
        public let rawChars: Int
        public let finalChars: Int
        public var delta: Int { finalChars - rawChars }
        public var isUnchanged: Bool { rawChars == finalChars && delta == 0 }
        public init(rawChars: Int, finalChars: Int) {
            self.rawChars = rawChars
            self.finalChars = finalChars
        }
    }

    public static func summarize(raw: String, final: String) -> Summary {
        // Use Character count, not UTF-16 / scalar count — matches what users see.
        Summary(rawChars: raw.count, finalChars: final.count)
    }

    /// Whitespace-split, preserving the punctuation glued to each word. Leading/
    /// trailing whitespace is collapsed; the spans rejoined will closely
    /// reproduce the original strings.
    public static func tokenize(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Word-level diff returning a list of contiguous spans (equal/added/removed).
    /// Adjacent same-kind spans are merged so the renderer doesn't see fragmented runs.
    public static func wordDiff(from raw: String, to final: String) -> [Span] {
        let a = tokenize(raw)
        let b = tokenize(final)
        if a.isEmpty && b.isEmpty { return [] }
        if a.isEmpty { return [.added(b.joined(separator: " "))] }
        if b.isEmpty { return [.removed(a.joined(separator: " "))] }

        // LCS DP table. lcs[i][j] = LCS length of a[0..<i] and b[0..<j].
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0..<n {
            for j in 0..<m {
                if a[i] == b[j] {
                    lcs[i + 1][j + 1] = lcs[i][j] + 1
                } else {
                    lcs[i + 1][j + 1] = max(lcs[i][j + 1], lcs[i + 1][j])
                }
            }
        }

        // Walk the table from (n,m) backward to produce an ordered op stream.
        enum Op { case equal(String), removed(String), added(String) }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                ops.append(.equal(a[i - 1])); i -= 1; j -= 1
            } else if lcs[i - 1][j] > lcs[i][j - 1] {
                ops.append(.removed(a[i - 1])); i -= 1
            } else {
                // Tie or added-side advantage: emit `added` first during the
                // backward walk so it lands AFTER `removed` once we reverse.
                // This gives consumers the natural "what was there → what it
                // became" reading order on substitutions.
                ops.append(.added(b[j - 1])); j -= 1
            }
        }
        while i > 0 { ops.append(.removed(a[i - 1])); i -= 1 }
        while j > 0 { ops.append(.added(b[j - 1])); j -= 1 }
        ops.reverse()

        // Merge adjacent same-kind ops back into single spans, joining tokens with
        // spaces. A trailing space on every span except the last keeps later
        // concatenation readable; the renderer relies on this for spacing.
        var spans: [Span] = []
        var pendingKind: String = ""
        var pendingWords: [String] = []

        func flush(isLast: Bool) {
            guard !pendingWords.isEmpty else { return }
            let joined = pendingWords.joined(separator: " ") + (isLast ? "" : " ")
            switch pendingKind {
            case "equal":   spans.append(.equal(joined))
            case "added":   spans.append(.added(joined))
            case "removed": spans.append(.removed(joined))
            default: break
            }
            pendingWords.removeAll(keepingCapacity: true)
        }

        for (idx, op) in ops.enumerated() {
            let (kind, word): (String, String)
            switch op {
            case .equal(let w):   (kind, word) = ("equal", w)
            case .added(let w):   (kind, word) = ("added", w)
            case .removed(let w): (kind, word) = ("removed", w)
            }
            if kind != pendingKind {
                flush(isLast: false)
                pendingKind = kind
            }
            pendingWords.append(word)
            if idx == ops.count - 1 { flush(isLast: true) }
        }
        return spans
    }
}
