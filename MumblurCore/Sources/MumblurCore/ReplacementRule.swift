// MumblurCore/Sources/MumblurCore/ReplacementRule.swift
import Foundation

public struct ReplacementRule: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let profileID: String
    public var pattern: String
    public var replacement: String
    public var isRegex: Bool
    public var caseSensitive: Bool
    public var wordBoundary: Bool
    public var sortOrder: Int

    public init(id: Int64, profileID: String, pattern: String, replacement: String,
                isRegex: Bool, caseSensitive: Bool, wordBoundary: Bool, sortOrder: Int) {
        self.id = id; self.profileID = profileID
        self.pattern = pattern; self.replacement = replacement
        self.isRegex = isRegex; self.caseSensitive = caseSensitive
        self.wordBoundary = wordBoundary; self.sortOrder = sortOrder
    }
}
