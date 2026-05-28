// MumblurCore/Sources/MumblurCore/Profile.swift
import Foundation

public struct Profile: Equatable, Sendable, Identifiable {
    public let id: String                 // UUID
    public var name: String
    public var language: String?          // nil = auto-detect
    public var modelID: String            // WhisperKit model name
    public var initialPrompt: String?     // free-form, optional
    public var vocab: [String]
    public var rules: [ReplacementRule]
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: String, name: String, language: String?, modelID: String,
                initialPrompt: String?, vocab: [String], rules: [ReplacementRule],
                createdAt: Date, updatedAt: Date, deletedAt: Date?) {
        self.id = id; self.name = name; self.language = language
        self.modelID = modelID; self.initialPrompt = initialPrompt
        self.vocab = vocab; self.rules = rules
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}
