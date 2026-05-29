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

// MARK: - LLMEditorBodyShapeTests

final class LLMEditorBodyShapeTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.stallSeconds = 0
        super.tearDown()
    }

    /// Capture the raw request body sent by editFailOpen.
    private func captureBody(_ cfg: LLMServerConfig, text: String = "raw",
                             instructions: String = "instr") async throws -> [String: Any] {
        nonisolated(unsafe) var captured: Data?
        StubURLProtocol.handler = { req in
            captured = req.httpBodyStreamData() ?? req.httpBody
            return (200, chatBody("ok"))
        }
        let ed = OpenAICompatibleEditor(config: cfg, session: stubSession())
        _ = try await ed.editFailOpen(text, instructions: instructions)
        let data = try XCTUnwrap(captured)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMode1_emitsMaxTokensAndTemperatureWhenSet() async throws {
        var cfg = LLMServerConfig(enabled: true, model: "m", timeoutMs: 5000)
        cfg.maxTokens = 256; cfg.temperature = 0.3
        let body = try await captureBody(cfg)
        XCTAssertEqual(body["max_tokens"] as? Int, 256)
        XCTAssertEqual(body["temperature"] as? Double, 0.3)
    }

    func testMode1_omitsKnobsWhenNil() async throws {
        var cfg = LLMServerConfig(enabled: true, model: "m", timeoutMs: 5000)
        cfg.maxTokens = nil; cfg.temperature = nil
        let body = try await captureBody(cfg)
        XCTAssertNil(body["max_tokens"])
        XCTAssertNil(body["temperature"])
    }

    func testMode1_extraBodyMergesNewKeys_butCanonicalWins() async throws {
        var cfg = LLMServerConfig(enabled: true, model: "real", timeoutMs: 5000)
        cfg.extraBodyJSON = "{\"top_p\":0.9, \"model\":\"hacked\", \"stream\":true}"
        let body = try await captureBody(cfg)
        XCTAssertEqual(body["top_p"] as? Double, 0.9)
        // Canonical wins: extra must not override model or stream
        XCTAssertEqual(body["model"] as? String, "real")
        XCTAssertEqual(body["stream"] as? Bool, false)
    }

    func testMode1_invalidExtraBody_failsOpen_noRequest() async throws {
        nonisolated(unsafe) var hit = false
        StubURLProtocol.handler = { _ in hit = true; return (200, chatBody("x")) }
        var cfg = LLMServerConfig(enabled: true, model: "m", timeoutMs: 5000)
        cfg.extraBodyJSON = "{not json"
        let ed = OpenAICompatibleEditor(config: cfg, session: stubSession())
        let out = try await ed.editFailOpen("raw", instructions: "fix")
        XCTAssertEqual(out, "raw")
        XCTAssertFalse(hit)
    }

    func testMode2_templateSubstitutesTypedValues() async throws {
        var cfg = LLMServerConfig(enabled: true, model: "mymodel", timeoutMs: 5000)
        cfg.maxTokens = 100
        cfg.temperature = 0.7
        cfg.requestTemplate = "{\"model\":\"{{model}}\",\"prompt\":\"{{text}}\",\"system\":\"{{instructions}}\",\"max_tokens\":\"{{max_tokens}}\",\"temperature\":\"{{temperature}}\"}"
        let body = try await captureBody(cfg, text: "hello", instructions: "be terse")
        XCTAssertEqual(body["model"] as? String, "mymodel")
        XCTAssertEqual(body["prompt"] as? String, "hello")
        XCTAssertEqual(body["system"] as? String, "be terse")
        XCTAssertEqual(body["max_tokens"] as? Int, 100)
        XCTAssertEqual(body["temperature"] as? Double, 0.7)
    }

    func testMode2_textWithSpecialChars_safeUnderTemplate() async throws {
        var cfg = LLMServerConfig(enabled: true, model: "m", timeoutMs: 5000)
        cfg.requestTemplate = "{\"prompt\":\"{{text}}\"}"
        // Newline, quote, backslash, unicode — must round-trip through JSONSerialization safely.
        let nasty = "line1\n\"quoted\" with \\backslash and 漢字"
        let body = try await captureBody(cfg, text: nasty)
        XCTAssertEqual(body["prompt"] as? String, nasty)
    }

    func testMode2_invalidTemplate_failsOpen() async throws {
        nonisolated(unsafe) var hit = false
        StubURLProtocol.handler = { _ in hit = true; return (200, chatBody("x")) }
        var cfg = LLMServerConfig(enabled: true, model: "m", timeoutMs: 5000)
        cfg.requestTemplate = "not json"
        let ed = OpenAICompatibleEditor(config: cfg, session: stubSession())
        let out = try await ed.editFailOpen("raw", instructions: "fix")
        XCTAssertEqual(out, "raw")
        XCTAssertFalse(hit)
    }

    func testContentPath_walksJSONPointer() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"data":{"items":[{"v":"hello"}]}}"#.utf8)) }
        var cfg = LLMServerConfig(enabled: true, model: "m", timeoutMs: 5000)
        cfg.contentPath = "/data/items/0/v"
        let ed = OpenAICompatibleEditor(config: cfg, session: stubSession())
        let out = try await ed.editFailOpen("raw", instructions: "fix")
        XCTAssertEqual(out, "hello")
    }

    func testContentFallbackPath_usedWhenPrimaryEmpty() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"choices":[{"message":{"content":"","reasoning_content":"thoughts here"}}]}"#.utf8))
        }
        var cfg = LLMServerConfig(enabled: true, model: "m", timeoutMs: 5000)
        cfg.contentPath = "/choices/0/message/content"
        cfg.contentFallbackPath = "/choices/0/message/reasoning_content"
        let ed = OpenAICompatibleEditor(config: cfg, session: stubSession())
        let out = try await ed.editFailOpen("raw", instructions: "fix")
        XCTAssertEqual(out, "thoughts here")
    }

    func testContent_bothPathsEmpty_failsOpenToInput() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8))
        }
        var cfg = LLMServerConfig(enabled: true, model: "m", timeoutMs: 5000)
        let ed = OpenAICompatibleEditor(config: cfg, session: stubSession())
        let out = try await ed.editFailOpen("raw", instructions: "fix")
        XCTAssertEqual(out, "raw")
    }
}

// MARK: - LLMEditorProbeTests

final class LLMEditorProbeTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.stallSeconds = 0
        super.tearDown()
    }

    func testProbe_disabled() async {
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: false, model: "m", timeoutMs: 5000),
            session: stubSession())
        let r = await ed.probe()
        if case .disabled = r { return }
        XCTFail("expected .disabled, got \(r)")
    }

    func testProbe_invalidURL() async {
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, baseURL: "", model: "m", timeoutMs: 5000),
            session: stubSession())
        let r = await ed.probe()
        if case .invalidURL = r { return }
        XCTFail("expected .invalidURL, got \(r)")
    }

    func testProbe_success() async {
        StubURLProtocol.handler = { _ in (200, chatBody("hi there")) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, model: "m", timeoutMs: 5000),
            session: stubSession())
        let r = await ed.probe()
        if case .success(let c) = r { XCTAssertEqual(c, "hi there"); return }
        XCTFail("expected .success, got \(r)")
    }

    func testProbe_successEmpty() async {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8))
        }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, model: "m", timeoutMs: 5000),
            session: stubSession())
        let r = await ed.probe()
        if case .successEmpty(let excerpt) = r {
            XCTAssertFalse(excerpt.isEmpty)
            return
        }
        XCTFail("expected .successEmpty, got \(r)")
    }

    func testProbe_httpFailure() async {
        StubURLProtocol.handler = { _ in (500, Data("oops".utf8)) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, model: "m", timeoutMs: 5000),
            session: stubSession())
        let r = await ed.probe()
        if case .httpFailure(let s, _) = r { XCTAssertEqual(s, 500); return }
        XCTFail("expected .httpFailure, got \(r)")
    }

    func testProbe_jsonFailure() async {
        StubURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, model: "m", timeoutMs: 5000),
            session: stubSession())
        let r = await ed.probe()
        if case .jsonFailure(let excerpt) = r {
            XCTAssertTrue(excerpt.contains("not json"))
            return
        }
        XCTFail("expected .jsonFailure, got \(r)")
    }

    func testProbe_requestBuildFailure_invalidTemplate() async {
        var cfg = LLMServerConfig(enabled: true, model: "m", timeoutMs: 5000)
        cfg.requestTemplate = "not json"
        let ed = OpenAICompatibleEditor(config: cfg, session: stubSession())
        let r = await ed.probe()
        if case .requestBuildFailure = r { return }
        XCTFail("expected .requestBuildFailure, got \(r)")
    }

    func testProbe_timeout() async {
        StubURLProtocol.stallSeconds = 5.0
        StubURLProtocol.handler = { _ in (200, chatBody("late")) }
        let ed = OpenAICompatibleEditor(
            config: LLMServerConfig(enabled: true, model: "m", timeoutMs: 300),
            session: stubSession())
        let start = Date()
        let r = await ed.probe()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0)
        if case .timeout = r { return }
        XCTFail("expected .timeout, got \(r)")
    }
}
