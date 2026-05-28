// MumblurCore/Tests/MumblurCoreTests/TranscriptPostProcessorTests.swift
import XCTest
@testable import MumblurCore

final class TranscriptPostProcessorTests: XCTestCase {

    private func r(_ pattern: String, _ replacement: String,
                   isRegex: Bool = false, caseSensitive: Bool = false,
                   wordBoundary: Bool = true, sortOrder: Int = 0) -> ReplacementRule {
        ReplacementRule(id: 0, profileID: "p", pattern: pattern, replacement: replacement,
                        isRegex: isRegex, caseSensitive: caseSensitive,
                        wordBoundary: wordBoundary, sortOrder: sortOrder)
    }

    func testLiteralReplaceWithWordBoundary_doesNotMatchInsideWords() {
        let p = TranscriptPostProcessor()
        let out = p.apply("questionable", rules: [r("question", "QUESTION")])
        XCTAssertEqual(out, "questionable")
    }

    func testLiteralReplaceWithoutWordBoundary_matchesAnywhere() {
        let p = TranscriptPostProcessor()
        let out = p.apply("questionable", rules: [r("question", "QUESTION", wordBoundary: false)])
        XCTAssertEqual(out, "QUESTIONable")
    }

    func testCaseInsensitiveByDefault() {
        let p = TranscriptPostProcessor()
        let out = p.apply("Hello world", rules: [r("hello", "Hi")])
        XCTAssertEqual(out, "Hi world")
    }

    func testCaseSensitiveOnly() {
        let p = TranscriptPostProcessor()
        let out = p.apply("Hello hello", rules: [r("hello", "Hi", caseSensitive: true)])
        XCTAssertEqual(out, "Hello Hi")
    }

    func testRegexReplace() {
        let p = TranscriptPostProcessor()
        let out = p.apply("call 555-1234", rules: [r(#"\b\d{3}-\d{4}\b"#, "[redacted]",
                                                     isRegex: true)])
        XCTAssertEqual(out, "call [redacted]")
    }

    func testRulesAppliedInSortOrder() {
        let p = TranscriptPostProcessor()
        let out = p.apply("a", rules: [
            r("a", "b", sortOrder: 0),
            r("b", "c", sortOrder: 1),
        ])
        XCTAssertEqual(out, "c")
    }

    func testInvalidRegex_isSkipped_notFatal() {
        let p = TranscriptPostProcessor()
        let out = p.apply("hello", rules: [r("[", "x", isRegex: true), r("hello", "Hi")])
        XCTAssertEqual(out, "Hi")
    }
}
