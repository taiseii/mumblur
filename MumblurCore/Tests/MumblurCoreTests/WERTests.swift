// MumblurCore/Tests/MumblurCoreTests/WERTests.swift
import XCTest
@testable import MumblurCore

final class WERNormalizerTests: XCTestCase {
    func testLowercasing_stripsPunctuationAndCollapsesWhitespace() {
        let n = WERNormalizer()
        XCTAssertEqual(n.normalize(" Hello, World!! "), "hello world")
    }
    func testNumbersAreLeftAsTokens() {
        let n = WERNormalizer()
        XCTAssertEqual(n.normalize("Take 12 apples."), "take 12 apples")
    }
}

final class WERCalculatorTests: XCTestCase {
    private let w = WERCalculator()
    func testZeroErrorsWhenIdentical() {
        XCTAssertEqual(w.wer(reference: "the quick brown fox", hypothesis: "the quick brown fox"), 0.0)
    }
    func testOneSubstitution_inFourWords() {
        XCTAssertEqual(w.wer(reference: "the quick brown fox", hypothesis: "the slow brown fox"), 0.25, accuracy: 1e-9)
    }
    func testInsertionDeletion() {
        XCTAssertEqual(w.wer(reference: "hello", hypothesis: "hello world"), 1.0, accuracy: 1e-9) // 1 ins / 1 ref
        XCTAssertEqual(w.wer(reference: "hello world", hypothesis: ""), 1.0, accuracy: 1e-9)      // 2 del / 2 ref
    }
    func testEmptyReference_isUndefined_returnsZeroIfHypothesisAlsoEmpty() {
        XCTAssertEqual(w.wer(reference: "", hypothesis: ""), 0.0)
    }
}
