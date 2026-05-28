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

/// Drives URLSession deterministically. `handler` returns (status, body) or
/// sleeps to model a stall; honors task cancellation via `stopLoading`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var stallSeconds: Double = 0
    private var cancelled = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        if Self.stallSeconds > 0 {
            let deadline = Date().addingTimeInterval(Self.stallSeconds)
            while Date() < deadline && !cancelled { Thread.sleep(forTimeInterval: 0.01) }
            if cancelled { return }
        }
        let (status, body) = Self.handler?(request) ?? (200, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { cancelled = true }
}

private func stubSession() -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: c)
}

private func chatBody(_ content: String) -> Data {
    Data(#"{"choices":[{"message":{"role":"assistant","content":"\#(content)"}}]}"#.utf8)
}

final class LLMEditorBehaviorTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.stallSeconds = 0
        super.tearDown()
    }

    func testSuccess_returnsEditedContent() async throws {
        StubURLProtocol.handler = { _ in (200, chatBody("cleaned text")) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, baseURL: "http://localhost:8080",
                                    model: "q", timeoutMs: 5000),
            session: stubSession())
        let out = try await ed.editFailOpen("raw text", instructions: "fix it")
        XCTAssertEqual(out, "cleaned text")
    }

    func testGloballyDisabled_returnsInput_noRequest() async throws {
        nonisolated(unsafe) var hit = false
        StubURLProtocol.handler = { _ in hit = true; return (200, chatBody("x")) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: false, baseURL: "http://localhost:8080",
                                    model: "q", timeoutMs: 5000),
            session: stubSession())
        let out = try await ed.editFailOpen("raw", instructions: "fix")
        XCTAssertEqual(out, "raw")
        XCTAssertFalse(hit)
    }

    func testNon2xx_failsOpen() async throws {
        StubURLProtocol.handler = { _ in (500, Data("oops".utf8)) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, model: "q", timeoutMs: 5000),
            session: stubSession())
        let out = try await ed.editFailOpen("raw", instructions: "fix")
        XCTAssertEqual(out, "raw")
    }

    func testMalformedJSON_failsOpen() async throws {
        StubURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, model: "q", timeoutMs: 5000),
            session: stubSession())
        let out = try await ed.editFailOpen("raw", instructions: "fix")
        XCTAssertEqual(out, "raw")
    }

    func testEmptyCompletion_failsOpenToInput() async throws {
        StubURLProtocol.handler = { _ in (200, chatBody("   ")) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, model: "q", timeoutMs: 5000),
            session: stubSession())
        let out = try await ed.editFailOpen("raw", instructions: "fix")
        XCTAssertEqual(out, "raw")
    }

    func testTimeout_failsOpen_withinBudget() async throws {
        StubURLProtocol.stallSeconds = 5.0
        StubURLProtocol.handler = { _ in (200, chatBody("late")) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, model: "q", timeoutMs: 300),
            session: stubSession())
        let start = Date()
        let out = try await ed.editFailOpen("raw", instructions: "fix")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(out, "raw")
        XCTAssertLessThan(elapsed, 2.0)
    }

    func testExternalCancellation_propagatesNotFailOpen() async throws {
        StubURLProtocol.stallSeconds = 5.0          // keep the request in-flight
        StubURLProtocol.handler = { _ in (200, chatBody("late")) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, model: "q", timeoutMs: 10_000), // long, so the timeout race won't fire first
            session: stubSession())
        let task = Task { try await ed.editFailOpen("raw", instructions: "fix") }
        try await Task.sleep(nanoseconds: 200_000_000)   // let the request start
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation to propagate, but it returned a value (fail-open)")
        } catch is CancellationError {
            // expected — cancellation propagated, not swallowed
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testRequestBody_hasSystemAndUserMessages() async throws {
        nonisolated(unsafe) var captured: Data?
        StubURLProtocol.handler = { req in
            captured = req.httpBodyStreamData() ?? req.httpBody
            return (200, chatBody("ok"))
        }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, model: "mymodel", timeoutMs: 5000),
            session: stubSession())
        _ = try await ed.editFailOpen("hello", instructions: "be terse")
        let json = try XCTUnwrap(captured).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let messages = json?["messages"] as? [[String: String]]
        XCTAssertEqual(json?["model"] as? String, "mymodel")
        XCTAssertEqual(messages?.first?["role"], "system")
        XCTAssertEqual(messages?.first?["content"], "be terse")
        XCTAssertEqual(messages?.last?["role"], "user")
        XCTAssertEqual(messages?.last?["content"], "hello")
    }
}

// URLProtocol can receive the body as a stream; read it for assertions.
private extension URLRequest {
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); let size = 4096; var buf = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: size)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}
