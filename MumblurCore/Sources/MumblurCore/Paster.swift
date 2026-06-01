import Foundation
import AppKit
import CoreGraphics
import os

public protocol Pasting: Sendable {
    func paste(_ text: String) async
}

public protocol KeystrokeSending: Sendable {
    func sendCmdV()
}

/// Synthesizes ⌘V via CGEvent. Requires Accessibility permission to actually work
/// against another app, but creating the events is harmless without it (the post
/// is a no-op without trust).
public struct DefaultKeystrokeSender: KeystrokeSending {
    public init() {}
    public func sendCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

@MainActor
public struct Paster: Pasting {
    private let keystroke: KeystrokeSending
    private let pasteboard: NSPasteboard

    /// `pasteboard` is injectable so tests can use an isolated, uniquely-named
    /// pasteboard instead of the shared `.general` one (which races under
    /// parallel test execution).
    public init(keystroke: KeystrokeSending = DefaultKeystrokeSender(),
                pasteboard: NSPasteboard = .general) {
        self.keystroke = keystroke
        self.pasteboard = pasteboard
    }

    public func paste(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        keystroke.sendCmdV()
        Logger.paste.debug("pasted \(text.count) chars")
    }
}
