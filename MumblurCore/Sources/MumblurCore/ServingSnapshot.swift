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
    public let llmEdit: LLMEditConfig

    public init(profileID: String, profileName: String, modelID: String,
                language: String?, prompt: PromptPayload, rules: [ReplacementRule],
                llmEdit: LLMEditConfig = .disabled) {
        self.profileID = profileID; self.profileName = profileName
        self.modelID = modelID; self.language = language
        self.prompt = prompt; self.rules = rules
        self.llmEdit = llmEdit
    }

    /// Copy with a replaced `llmEdit` — used by `Transcriber.updateLLMEdit` to
    /// patch active-profile AI settings without a model reload.
    public func with(llmEdit: LLMEditConfig) -> ServingSnapshot {
        ServingSnapshot(profileID: profileID, profileName: profileName, modelID: modelID,
                        language: language, prompt: prompt, rules: rules, llmEdit: llmEdit)
    }
}
