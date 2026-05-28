// App/Settings/OpenSettingsTrampoline.swift
import SwiftUI
import AppKit

extension Notification.Name {
    static let openSettingsRequest  = Notification.Name("mumblur.openSettingsRequest")
    static let settingsWindowClosed = Notification.Name("mumblur.settingsWindowClosed")
}

/// Tiny invisible window that hosts `@Environment(\.openSettings)` so the action
/// has a SwiftUI render tree to attach to (required on macOS Tahoe 26). Listens
/// for `.openSettingsRequest`; toggles activation policy from the current value
/// to `.regular` briefly, then restores it after the Settings window closes.
struct OpenSettingsTrampolineView: View {
    @Environment(\.openSettings) private var openSettings
    @State private var savedPolicy: NSApplication.ActivationPolicy?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequest)) { _ in
                Task { @MainActor in
                    if savedPolicy == nil { savedPolicy = NSApp.activationPolicy() }
                    NSApp.setActivationPolicy(.regular)
                    try? await Task.sleep(for: .milliseconds(80))
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsWindowClosed)) { _ in
                Task { @MainActor in
                    if let p = savedPolicy { NSApp.setActivationPolicy(p); savedPolicy = nil }
                }
            }
    }
}
