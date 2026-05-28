// LLMEditor.swift
import Foundation
import os

public struct LLMServerConfig: Equatable, Sendable {
    public var enabled: Bool
    public var baseURL: String
    public var model: String
    public var timeoutMs: Int

    public init(enabled: Bool = false,
                baseURL: String = "http://localhost:8080",
                model: String = "",
                timeoutMs: Int = 5000) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.model = model
        self.timeoutMs = LLMServerConfig.clampTimeout(timeoutMs)
    }

    public static let `default` = LLMServerConfig()

    /// Clamp to a sane window; callers pass possibly-garbage stored values.
    public static func clampTimeout(_ ms: Int) -> Int { min(max(ms, 500), 60_000) }
}

public struct LLMEditConfig: Equatable, Sendable {
    public static let defaultPrompt =
        "Fix punctuation, capitalization, and remove filler words. " +
        "Do not change meaning or add content. Return only the corrected text."
    public static let disabled = LLMEditConfig(enabled: false, prompt: "")

    public let enabled: Bool
    public let prompt: String
    public init(enabled: Bool, prompt: String) {
        self.enabled = enabled
        self.prompt = prompt
    }
}

public protocol TranscriptEditing: Sendable {
    /// Best-effort cleanup. Returns `text` unchanged on any network/timeout/
    /// parse failure, when globally disabled, or when unconfigured. Propagates
    /// `CancellationError` so a cancelled worker never proceeds to paste.
    func editFailOpen(_ text: String, instructions: String) async throws -> String
}

/// Default seam: identity. Used as the `Runner.init` default so existing call
/// sites (incl. ~10 test sites) keep compiling, and as the production default
/// until the real editor is injected.
public struct NoOpEditor: TranscriptEditing {
    public init() {}
    public func editFailOpen(_ text: String, instructions: String) async throws -> String { text }
}

public actor OpenAICompatibleEditor: TranscriptEditing {
    private var config: LLMServerConfig
    private let session: URLSession

    public init(config: LLMServerConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = Double(config.timeoutMs) / 1000.0
            self.session = URLSession(configuration: c)
        }
    }

    public func configure(_ config: LLMServerConfig) { self.config = config }

    /// Normalize a user-entered base URL into the chat-completions endpoint.
    /// Accepts `http://host:port`, a trailing `/`, or a trailing `/v1`.
    static func endpoint(base: String) -> URL? {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1") { s.removeLast(3) }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + "/v1/chat/completions")
    }

    private struct TimeoutError: Error {}

    private struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let stream: Bool
    }
    private struct ChatResponse: Decodable {
        struct Choice: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }
        let choices: [Choice]
    }

    public func editFailOpen(_ text: String, instructions: String) async throws -> String {
        let cfg = config
        guard cfg.enabled, let url = Self.endpoint(base: cfg.baseURL) else { return text }
        let model = cfg.model
        let session = self.session
        do {
            let edited = try await Self.race(timeoutMs: cfg.timeoutMs) {
                try await Self.perform(session: session, url: url, model: model,
                                       system: instructions, user: text)
            }
            let trimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? text : trimmed
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()   // URLSession surfaces task cancellation as URLError.cancelled
        } catch {
            if Task.isCancelled { throw CancellationError() }   // belt-and-suspenders
            Logger.transcribe.info("LLM edit failed open: \(error.localizedDescription, privacy: .public)")
            return text
        }
    }

    private static func perform(session: URLSession, url: URL, model: String,
                                system: String, user: String) async throws -> String {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ChatRequest(model: model,
                               messages: [.init(role: "system", content: system),
                                          .init(role: "user", content: user)],
                               stream: false)
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw URLError(.cannotParseResponse)
        }
        return content
    }

    /// First-result race between the operation and a sleep. The sleep winning
    /// throws TimeoutError (→ fail-open). `defer { cancelAll() }` ensures the
    /// loser is cancelled; `session.data(for:)` is cancellation-cooperative so
    /// the wall-clock cap is hard. External cancellation propagates as
    /// CancellationError.
    private static func race(timeoutMs: Int,
                             _ op: @escaping @Sendable () async throws -> String) async throws -> String {
        try await withThrowingTaskGroup(of: String?.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                return nil
            }
            while let result = try await group.next() {
                if let value = result { return value }
                throw TimeoutError()
            }
            throw TimeoutError()
        }
    }
}
