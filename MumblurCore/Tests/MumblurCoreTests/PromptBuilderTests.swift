// MumblurCore/Tests/MumblurCoreTests/PromptBuilderTests.swift
import XCTest
@testable import MumblurCore

/// Pure, value-only tokenizer: one word = one token-id equal to its position
/// in the input string. Stateless and trivially Sendable.
private let positionalTokenize: TokenizeText = { text in
    text.split(separator: " ").enumerated().map { (i, _) in i }
}

final class PromptBuilderTests: XCTestCase {

    func testRenders_initialPromptFirst_thenVocab_inGivenOrder() throws {
        let p = try PromptBuilder.build(
            initialPrompt: "Lab note:",
            vocab: ["WhisperKit", "Questable", "Mumblur"],
            budget: .max,
            tokenize: positionalTokenize)
        XCTAssertTrue(p.sourceText.hasPrefix("Lab note:"))
        XCTAssertEqual(p.omittedTerms, [])
        XCTAssertEqual(p.promptTokens.count,
                       p.sourceText.split(separator: " ").count)
    }

    func testTruncates_byTokenBudget_andReportsOmitted() throws {
        // "Glossary: a, b, c, d" → 5 whitespace tokens. Budget 4 drops only "d".
        let p = try PromptBuilder.build(
            initialPrompt: nil,
            vocab: ["a", "b", "c", "d"],
            budget: .tokens(4),
            tokenize: positionalTokenize)
        XCTAssertEqual(p.promptTokens.count, 4)
        XCTAssertEqual(p.omittedTerms, ["d"])
    }

    func testEmptyProfileYieldsEmptyPayload() throws {
        let p = try PromptBuilder.build(
            initialPrompt: nil, vocab: [],
            budget: .tokens(100), tokenize: positionalTokenize)
        XCTAssertEqual(p, .empty)
    }
}
