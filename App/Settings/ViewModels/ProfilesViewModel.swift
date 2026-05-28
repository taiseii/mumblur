// App/Settings/ViewModels/ProfilesViewModel.swift
import SwiftUI
import MumblurCore

@MainActor
final class ProfilesViewModel: ObservableObject {
    struct Coordinator {
        let switchActive: @MainActor (Profile) async -> Void
        let createProfile: @MainActor (_ name: String, _ modelID: String) async throws -> Profile
        let softDelete:    @MainActor (_ id: String) async throws -> Void
    }

    @Published var selection: String?

    private let coordinator: Coordinator

    init(coordinator: Coordinator) { self.coordinator = coordinator }

    func switchTo(_ profile: Profile) async { await coordinator.switchActive(profile) }
    func create(name: String, modelID: String) async throws -> Profile {
        try await coordinator.createProfile(name, modelID)
    }
    func delete(_ id: String) async throws { try await coordinator.softDelete(id) }
}
