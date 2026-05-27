import Foundation
import CoreGraphics
import os

public enum HotkeyEvent: Sendable {
    case press
    case release
}

public protocol HotkeyListening: AnyObject, Sendable {
    func start() throws
    func stop()
}

/// Pure state machine — no CGEventTap involvement, unit-testable.
/// Call `handle(keycode:)` once per .flagsChanged event for the target key.
/// Toggle semantics: alternating calls emit press, release, press, ...
public struct HotkeyDispatcher: Sendable {
    private let targetKeycode: CGKeyCode
    private let onPress: @Sendable () -> Void
    private let onRelease: @Sendable () -> Void
    private var isDown: Bool = false

    public init(
        targetKeycode: CGKeyCode,
        onPress: @escaping @Sendable () -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) {
        self.targetKeycode = targetKeycode
        self.onPress = onPress
        self.onRelease = onRelease
    }

    public mutating func handle(keycode: CGKeyCode) {
        guard keycode == targetKeycode else { return }
        if isDown {
            isDown = false
            onRelease()
        } else {
            isDown = true
            onPress()
        }
    }
}

/// Installs a CGEventTap on `kCGSessionEventTap` watching .flagsChanged events.
/// Requires both Accessibility and Input Monitoring on macOS 14+.
public final class Hotkey: HotkeyListening, @unchecked Sendable {
    public static let rightOptionKeycode: CGKeyCode = 0x3D

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dispatcher: HotkeyDispatcher
    private let lock = NSLock()

    public init(
        targetKeycode: CGKeyCode = Hotkey.rightOptionKeycode,
        onEvent: @escaping @Sendable (HotkeyEvent) -> Void
    ) {
        self.dispatcher = HotkeyDispatcher(
            targetKeycode: targetKeycode,
            onPress: { onEvent(.press) },
            onRelease: { onEvent(.release) }
        )
    }

    public func start() throws {
        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Hotkey.callback,
            userInfo: userInfo
        ) else {
            throw NSError(
                domain: "MumblurCore.Hotkey",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "CGEvent.tapCreate failed (missing Accessibility / Input Monitoring?)"]
            )
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        Logger.hotkey.debug("event tap started")
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        Logger.hotkey.debug("event tap stopped")
    }

    private static let callback: CGEventTapCallBack = { _, _, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<Hotkey>.fromOpaque(userInfo).takeUnretainedValue()
        let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        me.lock.lock()
        me.dispatcher.handle(keycode: kc)
        me.lock.unlock()
        return Unmanaged.passUnretained(event)
    }
}
