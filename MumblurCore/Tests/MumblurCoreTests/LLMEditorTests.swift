// LLMEditorTests.swift
import XCTest
@testable import MumblurCore

final class LLMEditorURLTests: XCTestCase {
    func testEndpoint_normalizesBase() {
        XCTAssertEqual(OpenAICompatibleEditor.endpoint(base: "http://localhost:8080")?.absoluteString,
                       "http://localhost:8080/v1/chat/completions")
        XCTAssertEqual(OpenAICompatibleEditor.endpoint(base: "http://localhost:8080/")?.absoluteString,
                       "http://localhost:8080/v1/chat/completions")
        XCTAssertEqual(OpenAICompatibleEditor.endpoint(base: "http://localhost:8080/v1")?.absoluteString,
                       "http://localhost:8080/v1/chat/completions")
        XCTAssertNil(OpenAICompatibleEditor.endpoint(base: ""))
        XCTAssertNil(OpenAICompatibleEditor.endpoint(base: "   "))
    }
}
