import XCTest
@testable import MumblurCore

final class TextDiffTests: XCTestCase {
    func testTokenize_splitsOnWhitespaceAndKeepsPunctuationOnToken() {
        XCTAssertEqual(TextDiff.tokenize("hi  there world"), ["hi", "there", "world"])
        XCTAssertEqual(TextDiff.tokenize("Hello, world."), ["Hello,", "world."])
        XCTAssertEqual(TextDiff.tokenize(""), [])
    }

    func testWordDiff_identical_yieldsAllEqualSpans() {
        let spans = TextDiff.wordDiff(from: "hello world", to: "hello world")
        XCTAssertEqual(spans, [.equal("hello world")])
    }

    func testWordDiff_pureDeletion_marksRemovedWord() {
        // "um the cat" -> "the cat": "um " should be flagged removed.
        let spans = TextDiff.wordDiff(from: "um the cat", to: "the cat")
        XCTAssertEqual(spans, [.removed("um "), .equal("the cat")])
    }

    func testWordDiff_pureInsertion_marksAddedWord() {
        let spans = TextDiff.wordDiff(from: "the cat", to: "the big cat")
        XCTAssertEqual(spans, [.equal("the "), .added("big "), .equal("cat")])
    }

    func testWordDiff_substitution_yieldsRemovedThenAdded() {
        // "the cat sat" -> "the dog sat"
        let spans = TextDiff.wordDiff(from: "the cat sat", to: "the dog sat")
        XCTAssertEqual(spans, [.equal("the "), .removed("cat "), .added("dog "), .equal("sat")])
    }

    func testWordDiff_emptyEitherSide_handled() {
        XCTAssertEqual(TextDiff.wordDiff(from: "", to: "hello"), [.added("hello")])
        XCTAssertEqual(TextDiff.wordDiff(from: "hello", to: ""), [.removed("hello")])
        XCTAssertEqual(TextDiff.wordDiff(from: "", to: ""), [])
    }

    // MARK: - Summary

    func testSummarize_reportsCharCountsAndDelta() {
        let s = TextDiff.summarize(raw: "hello world", final: "hi world")
        XCTAssertEqual(s.rawChars, 11)
        XCTAssertEqual(s.finalChars, 8)
        XCTAssertEqual(s.delta, -3)
        XCTAssertFalse(s.isUnchanged)
    }

    func testSummarize_unchanged_marksFlag() {
        let s = TextDiff.summarize(raw: "same", final: "same")
        XCTAssertEqual(s.delta, 0)
        XCTAssertTrue(s.isUnchanged)
    }
}
