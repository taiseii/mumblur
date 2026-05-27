import Foundation
import AppKit
import AVFoundation
import MumblurCore
import os

@MainActor
final class PermissionsCoordinator {
    struct Snapshot: Equatable {
        var accessibility: PermissionResult
        var inputMonitoring: PermissionResult
        var microphone: PermissionResult
        var allGranted: Bool {
            accessibility == .granted
                && inputMonitoring == .granted
                && microphone == .granted
        }
    }

    private var timer: Timer?
    private let onChange: @MainActor (Snapshot) -> Void
    private var last: Snapshot?

    init(onChange: @escaping @MainActor (Snapshot) -> Void) {
        self.onChange = onChange
    }

    func bootstrap() async {
        let mic = await PermissionGate.ensureMicrophone()
        let acc = PermissionGate.ensureAccessibility(prompt: true)
        let im  = PermissionGate.ensureInputMonitoring(prompt: true)
        let snap = Snapshot(accessibility: acc, inputMonitoring: im, microphone: mic)
        last = snap
        onChange(snap)
        if !snap.allGranted { startPolling() }
    }

    func openSystemSettings(for pane: Pane) {
        let url: URL?
        switch pane {
        case .accessibility:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .inputMonitoring:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        case .microphone:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
        if let url { NSWorkspace.shared.open(url) }
    }

    enum Pane { case accessibility, inputMonitoring, microphone }

    // MARK: - Private

    private func startPolling() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
        Logger.perms.debug("started permission poll (2s)")
    }

    private func tick() {
        let mic = lastMicrophoneSync()   // sync read of cached AVCaptureDevice status
        let acc = PermissionGate.ensureAccessibility(prompt: false)
        let im  = PermissionGate.ensureInputMonitoring(prompt: false)
        let snap = Snapshot(accessibility: acc, inputMonitoring: im, microphone: mic)
        if snap != last {
            last = snap
            onChange(snap)
            if snap.allGranted {
                timer?.invalidate(); timer = nil
                Logger.perms.info("all permissions granted; poll stopped")
            }
        }
    }

    private func lastMicrophoneSync() -> PermissionResult {
        // AVCaptureDevice mic status is queryable synchronously.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .denied
        @unknown default: return .denied
        }
    }
}
