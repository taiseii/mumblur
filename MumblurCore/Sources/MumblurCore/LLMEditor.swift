// LLMEditor.swift
import Foundation
import os

public struct LLMServerConfig: Equatable, Sendable {
    public var enabled: Bool
    public var baseURL: String
    public var model: String
    public var timeoutMs: Int
    public var maxTokens: Int?
    public var temperature: Double?
    public var extraBodyJSON: String
    public var requestTemplate: String
    public var contentPath: String
    public var contentFallbackPath: String

    public init(enabled: Bool = false,
                baseURL: String = "http://localhost:8080",
                model: String = "",
                timeoutMs: Int = 5000,
                maxTokens: Int? = nil,
                temperature: Double? = nil,
                extraBodyJSON: String = "",
                requestTemplate: String = "",
                contentPath: String = "/choices/0/message/content",
                contentFallbackPath: String = "") {
        self.enabled = enabled
        self.baseURL = baseURL
        self.model = model
        self.timeoutMs = LLMServerConfig.clampTimeout(timeoutMs)
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.extraBodyJSON = extraBodyJSON
        self.requestTemplate = requestTemplate
        self.contentPath = contentPath
        self.contentFallbackPath = contentFallbackPath
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

// MARK: - ProbeResult

public enum ProbeResult: Sendable {
    /// Got non-empty content from the configured path.
    case success(content: String)
    /// 2xx + valid JSON but no content at either path.
    case successEmpty(responseExcerpt: String)
    /// Global enabled = false.
    case disabled
    /// baseURL empty or unparseable.
    case invalidURL
    /// Bad template or extra-body JSON.
    case requestBuildFailure(reason: String)
    /// Non-2xx HTTP status.
    case httpFailure(status: Int, responseExcerpt: String)
    /// 2xx but body is not parseable JSON.
    case jsonFailure(responseExcerpt: String)
    /// URLError or other network failure.
    case transportFailure(message: String)
    /// Race timed out.
    case timeout
}

// MARK: - OpenAICompatibleEditor

public actor OpenAICompatibleEditor: TranscriptEditing {
    private var config: LLMServerConfig
    private let session: URLSession

    public init(config: LLMServerConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let c = URLSessionConfiguration.ephemeral
            // Fixed generous backstop only. The authoritative wall-clock cap is
            // `race(timeoutMs:)`, which reads the CURRENT config.timeoutMs (clamped
            // ≤ 60s). Keeping the session timeout well above that ensures the race —
            // not a stale session value — owns the timeout, so configure(_:) changes
            // to timeoutMs take effect immediately without rebuilding the session.
            c.timeoutIntervalForRequest = 120
            self.session = URLSession(configuration: c)
        }
    }

    public func configure(_ config: LLMServerConfig) { self.config = config }

    /// Normalize a user-entered URL into the chat-completions endpoint.
    /// Accepts:
    /// - `http://host:port` → appends `/v1/chat/completions`
    /// - `http://host:port/` → trailing slash trimmed, then appends
    /// - `http://host:port/v1` → appends `/chat/completions`
    /// - `http://host:port/v1/chat/completions` → used as-is (full URL paste)
    /// - `http://host:port/chat/completions` → used as-is (non-versioned path)
    static func endpoint(base: String) -> URL? {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        let lower = s.lowercased()
        if lower.hasSuffix("/chat/completions") {
            // User pasted the full endpoint URL — use as-is.
            return URL(string: s)
        }
        if lower.hasSuffix("/v1") { s.removeLast(3) }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + "/v1/chat/completions")
    }

    // MARK: - Errors

    private struct TimeoutError: Error {}

    private enum RequestBuildError: Error, Sendable {
        case invalidTemplate(reason: String)
        case invalidExtraBody(reason: String)
    }

    // MARK: - Body Building

    private static func buildBody(model: String, instructions: String, text: String,
                                  cfg: LLMServerConfig) throws -> Data {
        let template = cfg.requestTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if template.isEmpty {
            return try buildBodyMode1(model: model, instructions: instructions, text: text, cfg: cfg)
        } else {
            return try buildBodyMode2(template: template, model: model,
                                      instructions: instructions, text: text, cfg: cfg)
        }
    }

    /// Mode 1: Canonical OpenAI Chat format.
    private static func buildBodyMode1(model: String, instructions: String, text: String,
                                       cfg: LLMServerConfig) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": text]
            ],
            "stream": false
        ]
        if let maxTokens = cfg.maxTokens { body["max_tokens"] = maxTokens }
        if let temperature = cfg.temperature { body["temperature"] = temperature }

        // Merge extraBodyJSON: canonical fields win (only add keys not already present).
        let extra = cfg.extraBodyJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            guard let extraData = extra.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: extraData),
                  let extraDict = parsed as? [String: Any] else {
                throw RequestBuildError.invalidExtraBody(
                    reason: "extraBodyJSON is not a valid JSON object")
            }
            for (key, value) in extraDict {
                if body[key] == nil { body[key] = value }
            }
        }

        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Mode 2: User-provided JSON template with typed placeholder substitution.
    private static func buildBodyMode2(template: String, model: String, instructions: String,
                                       text: String, cfg: LLMServerConfig) throws -> Data {
        guard let templateData = template.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: templateData) else {
            throw RequestBuildError.invalidTemplate(reason: "requestTemplate is not valid JSON")
        }
        let substituted = substituteNode(parsed, model: model, instructions: instructions,
                                         text: text, cfg: cfg)
        return try JSONSerialization.data(withJSONObject: substituted)
    }

    /// Recursively walks the parsed JSON tree and replaces exact placeholder strings
    /// with typed values. Only full-string matches trigger replacement.
    private static func substituteNode(_ node: Any, model: String, instructions: String,
                                       text: String, cfg: LLMServerConfig) -> Any {
        if let dict = node as? [String: Any] {
            return dict.mapValues { substituteNode($0, model: model, instructions: instructions,
                                                   text: text, cfg: cfg) }
        } else if let arr = node as? [Any] {
            return arr.map { substituteNode($0, model: model, instructions: instructions,
                                            text: text, cfg: cfg) }
        } else if let s = node as? String {
            switch s {
            case "{{model}}": return model
            case "{{instructions}}": return instructions
            case "{{text}}": return text
            case "{{max_tokens}}":
                if let v = cfg.maxTokens { return v as Any } else { return NSNull() }
            case "{{temperature}}":
                if let v = cfg.temperature { return v as Any } else { return NSNull() }
            default: return s
            }
        }
        return node
    }

    // MARK: - JSON Pointer

    /// RFC 6901 simplified JSON Pointer traversal.
    /// Empty pointer ("") → returns root.
    /// Non-empty pointer must start with "/"; otherwise returns nil.
    private static func jsonPointerValue(_ pointer: String, in root: Any) -> Any? {
        guard !pointer.isEmpty else { return root }
        guard pointer.hasPrefix("/") else { return nil }

        // Drop the leading "/" and split on "/"
        let tokens = pointer.dropFirst().components(separatedBy: "/")
        var current: Any = root
        for token in tokens {
            // Unescape: ~1 → "/" then ~0 → "~" (order matters per RFC 6901)
            let key = token.replacingOccurrences(of: "~1", with: "/")
                           .replacingOccurrences(of: "~0", with: "~")
            if let dict = current as? [String: Any] {
                guard let next = dict[key] else { return nil }
                current = next
            } else if let arr = current as? [Any] {
                guard key.allSatisfy(\.isNumber), let idx = Int(key), idx < arr.count else {
                    return nil
                }
                current = arr[idx]
            } else {
                return nil
            }
        }
        return current
    }

    // MARK: - Response Extraction

    /// Parse JSON from data; returns nil if unparseable.
    private static func parseJSON(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    /// Traverse the parsed JSON root using the configured content path(s).
    /// Returns non-empty trimmed string, or nil if not found.
    private static func traverse(root: Any, cfg: LLMServerConfig) -> String? {
        // Try primary path
        if !cfg.contentPath.isEmpty {
            if let v = jsonPointerValue(cfg.contentPath, in: root) as? String {
                let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        // Try fallback path
        if !cfg.contentFallbackPath.isEmpty {
            if let v = jsonPointerValue(cfg.contentFallbackPath, in: root) as? String {
                let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Best-effort first 200 bytes as UTF-8, newlines collapsed.
    private static func excerpt(_ data: Data) -> String {
        (String(data: data.prefix(200), encoding: .utf8) ?? "")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Extract content from raw response data.
    /// Returns (content, excerpt) where content is nil on parse failure or missing path.
    private static func extractContent(data: Data, cfg: LLMServerConfig) -> (content: String?, excerpt: String) {
        let ex = excerpt(data)
        guard let root = parseJSON(data) else {
            return (nil, ex)
        }
        return (traverse(root: root, cfg: cfg), ex)
    }

    // MARK: - Generic Race

    /// First-result race between the operation and a sleep. The sleep winning
    /// throws TimeoutError (→ fail-open). `defer { cancelAll() }` ensures the
    /// loser is cancelled; `session.data(for:)` is cancellation-cooperative so
    /// the wall-clock cap is hard. External cancellation propagates as
    /// CancellationError.
    private static func race<T: Sendable>(timeoutMs: Int,
                                          _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
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

    // MARK: - editFailOpen

    public func editFailOpen(_ text: String, instructions: String) async throws -> String {
        let cfg = config
        let t0 = Date()
        guard cfg.enabled, let url = Self.endpoint(base: cfg.baseURL) else {
            let reason = "LLM edit skipped: cfg.enabled=\(cfg.enabled), urlOk=\(Self.endpoint(base: cfg.baseURL) != nil)"
            Logger.transcribe.notice("\(reason, privacy: .public)")
            return text
        }
        let model = cfg.model
        let session = self.session

        // Build body — fail open on bad template/extra-body, before any network call.
        let bodyData: Data
        do {
            bodyData = try Self.buildBody(model: model, instructions: instructions,
                                          text: text, cfg: cfg)
        } catch {
            Logger.transcribe.info("LLM body build failed: \(error.localizedDescription, privacy: .public)")
            return text
        }

        do {
            let data = try await Self.race(timeoutMs: cfg.timeoutMs) {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = bodyData
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            let (content, _) = Self.extractContent(data: data, cfg: cfg)
            let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
            if let content, !content.isEmpty {
                let msg = "LLM edit ok: in=\(text.count) out=\(content.count) ms=\(elapsed)"
                Logger.transcribe.notice("\(msg, privacy: .public)")
                return content
            }
            let msg = "LLM edit empty content, fail-open: in=\(text.count) ms=\(elapsed)"
            Logger.transcribe.notice("\(msg, privacy: .public)")
            return text
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            Logger.transcribe.info("LLM edit failed open: \(error.localizedDescription, privacy: .public)")
            return text
        }
    }

    // MARK: - probe()

    public func probe(text: String = "ping",
                      instructions: String = "Reply with: ok") async -> ProbeResult {
        let cfg = config
        let model = cfg.model
        let session = self.session

        guard cfg.enabled else { return .disabled }
        guard let url = Self.endpoint(base: cfg.baseURL) else { return .invalidURL }

        let bodyData: Data
        do {
            bodyData = try Self.buildBody(model: model, instructions: instructions,
                                          text: text, cfg: cfg)
        } catch let e as RequestBuildError {
            return .requestBuildFailure(reason: "\(e)")
        } catch {
            return .requestBuildFailure(reason: error.localizedDescription)
        }

        do {
            let (data, status) = try await Self.race(timeoutMs: cfg.timeoutMs) {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = bodyData
                let (data, resp) = try await session.data(for: req)
                let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
                return (data, statusCode)
            }

            guard (200..<300).contains(status) else {
                return .httpFailure(status: status, responseExcerpt: Self.excerpt(data))
            }

            // Distinguish bad JSON from valid-JSON-with-empty-content.
            guard let root = Self.parseJSON(data) else {
                return .jsonFailure(responseExcerpt: Self.excerpt(data))
            }

            if let content = Self.traverse(root: root, cfg: cfg) {
                return .success(content: content)
            } else {
                return .successEmpty(responseExcerpt: Self.excerpt(data))
            }

        } catch is TimeoutError {
            return .timeout
        } catch {
            return .transportFailure(message: error.localizedDescription)
        }
    }
}
