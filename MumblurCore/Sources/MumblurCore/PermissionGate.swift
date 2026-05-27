import Foundation
import AVFoundation
@preconcurrency import ApplicationServices
import IOKit.hid
import os

public enum PermissionResult: Sendable, Equatable {
    case granted
    case denied
    case prompted
}

public enum PermissionGate {
    /// Returns the *current* Accessibility trust state. Triggers the OS dialog as a
    /// side effect when `prompt == true` and trust is missing. Return value reflects
    /// the state at call time, NOT the user's eventual choice.
    public static func ensureAccessibility(prompt: Bool) -> PermissionResult {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: CFDictionary = [key: prompt as CFBoolean] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        let result: PermissionResult = trusted ? .granted : (prompt ? .prompted : .denied)
        Logger.perms.debug("accessibility check (prompt=\(prompt)) -> \(String(describing: result))")
        return result
    }

    /// Returns the current Input Monitoring (kIOHIDRequestTypeListenEvent) state.
    /// When `prompt == true` and the state is unknown, `IOHIDRequestAccess` triggers
    /// the OS dialog; this method still returns immediately with the pre-grant state.
    public static func ensureInputMonitoring(prompt: Bool) -> PermissionResult {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch access {
        case kIOHIDAccessTypeGranted:
            Logger.perms.debug("input monitoring: granted")
            return .granted
        case kIOHIDAccessTypeDenied:
            Logger.perms.debug("input monitoring: denied")
            return .denied
        default:
            if prompt {
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                Logger.perms.debug("input monitoring: prompted")
                return .prompted
            }
            return .denied
        }
    }

    /// Pops the AVCaptureDevice mic dialog and awaits the user's choice.
    public static func ensureMicrophone() async -> PermissionResult {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? .granted : .denied
        @unknown default:
            return .denied
        }
    }
}
