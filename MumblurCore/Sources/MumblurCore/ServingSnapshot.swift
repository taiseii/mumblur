// MumblurCore/Sources/MumblurCore/ServingSnapshot.swift
import Foundation

/// The immutable bundle that actually serves dictation. Held by the
/// `Transcriber` actor along with the loaded pipeline; returned alongside
/// `rawText` so persisted rows always reflect what produced the text.
public struct ServingSnapshot: Equatable, Sendable {
    public let profileID: String
    public let profileName: String
    public let modelID: String
    public let language: String?
    public let prompt: PromptPayload
    public let rules: [ReplacementRule]

    public init(profileID: String, profileName: String, modelID: String,
                language: String?, prompt: PromptPayload, rules: [ReplacementRule]) {
        self.profileID = profileID; self.profileName = profileName
        self.modelID = modelID; self.language = language
        self.prompt = prompt; self.rules = rules
    }
}
