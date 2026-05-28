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
