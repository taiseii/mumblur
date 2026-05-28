// MumblurCore/Sources/MumblurCore/ModelManager.swift
import Foundation
import os

public struct LoadedModel: Sendable {
    public let kit: any WhisperKitTranscribing
    public let tokenizer: any Tokenizing      // non-mutating; Tokenizing is Sendable
    public init(kit: any WhisperKitTranscribing, tokenizer: any Tokenizing) {
        self.kit = kit
        self.tokenizer = tokenizer
    }
}

public protocol ModelLoading: Sendable {
    func load(modelID: String) async throws -> LoadedModel
}

public enum ModelManagerError: Error, Equatable { case staleSwap }

public actor ModelManager {
    private let loader: any ModelLoading
    private let transcriber: Transcriber
    private var generation: UInt64 = 0

    public init(loader: any ModelLoading, transcriber: Transcriber) {
        self.loader = loader; self.transcriber = transcriber
    }

    /// Returns the committed `ServingSnapshot` on success. Throws if the load fails
    /// or if a newer `requestSwap` superseded this one before commit.
    public func requestSwap(to profile: Profile,
                            promptBudget: PromptBudget = .tokens(220)) async throws -> ServingSnapshot {
        generation &+= 1
        let mine = generation
        let model = try await loader.load(modelID: profile.modelID)
        // Build the prompt using THIS model's tokenizer, frozen into the snapshot.
        // `LoadedModel.tokenizer` is `Tokenizing & Sendable`; the call is non-mutating.
        let tokenizer = model.tokenizer
        let payload = try PromptBuilder.build(
            initialPrompt: profile.initialPrompt,
            vocab: profile.vocab,
            budget: promptBudget,
            tokenize: { try tokenizer.encode(text: $0) })
        // Reentrancy guard: commit only if this is still the most recent request.
        guard mine == generation else {
            Logger.app.info("dropping stale swap generation=\(mine) current=\(self.generation)")
            throw ModelManagerError.staleSwap
        }
        let snap = ServingSnapshot(
            profileID: profile.id, profileName: profile.name,
            modelID: profile.modelID, language: profile.language,
            prompt: payload, rules: profile.rules)
        await transcriber.commit(snapshot: snap, kit: model.kit)
        return snap
    }
}
