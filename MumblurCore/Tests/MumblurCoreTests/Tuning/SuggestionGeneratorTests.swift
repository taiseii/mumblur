// MumblurCore/Tests/MumblurCoreTests/Tuning/SuggestionGeneratorTests.swift
import XCTest
@testable import MumblurCore

final class SuggestionGeneratorTests: XCTestCase {

    func testRule_requiresSupportAndPrecision() {
        let gen = SuggestionGenerator(minSupport: 3, minPrecision: 0.8)
        let weak = gen.generateRules(from: [.init(produced: "x", expected: "y", count: 1, distinctExpected: 1)])
        XCTAssertTrue(weak.isEmpty)
        let strong = gen.generateRules(from: [.init(produced: "x", expected: "y", count: 3, distinctExpected: 1)])
        XCTAssertEqual(strong.first?.pattern, "x")
        XCTAssertEqual(strong.first?.replacement, "y")
    }

    func testRule_ambiguousProducedForm_isRejected() {
        let gen = SuggestionGenerator(minSupport: 4, minPrecision: 0.8)
        let amb = gen.generateRules(from: [.init(produced: "x", expected: "y", count: 4, distinctExpected: 2)])
        XCTAssertTrue(amb.isEmpty)
    }

    func testVocab_collectsFrequentMissedExpected() {
        let gen = SuggestionGenerator(minSupport: 2, minPrecision: 1.0)
        let vocab = gen.generateVocab(from: [
            .init(produced: "questionable", expected: "questable", count: 3, distinctExpected: 1),
            .init(produced: "test", expected: "test", count: 5, distinctExpected: 1),
        ])
        XCTAssertEqual(vocab, ["questable"])
    }
}
