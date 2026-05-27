# Mumblur — Swift Rewrite (Menu-Bar Push-to-Talk Dictation)

**Status:** Design proposed, pending approval
**Date:** 2026-05-27
**Target machine:** Apple Silicon (M3 Max, macOS Tahoe 26.x), single user
**Supersedes:** `2026-05-27-push-to-talk-dictation-design.md` (Python version) and `2026-05-27-mumbler-swift-design.md` (first Swift draft)

Project rename: the Python prototype was called `mumbler`; the Swift rewrite is **`mumblur`** (final name). Bundle identifier: `world.questable.mumblur`.

## 1. Why a rewrite

The Python prototype works end-to-end (24 passing tests, slow integration test transcribes the fixture in ~25 s). It fails at the last mile on macOS Tahoe 26.x because the OS will not honor Accessibility grants for ad-hoc-signed binaries running under terminals — neither Homebrew Python, nor Homebrew-cask Alacritty, nor pyenv-installed Python could be made trusted. The toggle in System Settings shows on, but `AXIsProcessTrusted()` returns `false`.

This is a stack mismatch, not a coding bug. macOS' permission model is built around `.app` bundles with stable identities. A Python script through `uv` through a terminal is exactly the chain Tahoe locked down. Repackaging the Python as a signed `.app` (via `py2app` or `briefcase`) would work but adds non-trivial build/signing infrastructure for a problem Swift solves natively.

The rewrite is therefore a port, not a redesign: the architecture (5 small modules with narrow contracts, locked state machine, worker, record-then-transcribe semantics) carries over verbatim. Only the implementation language and platform APIs change.

## 2. Goal

A local push-to-talk dictation tool for macOS Apple Silicon, distributed as `Mumblur.app`. The user holds **Right Option** while speaking; on release, the recorded audio is transcribed locally and pasted at the cursor in the active app. Everything runs on-device. No network.

## 3. Scope

### In scope (v1)

- A single `Mumblur.app` bundle (ad-hoc signed for personal use; no Apple Developer account needed).
- **SwiftUI `MenuBarExtra`** UI: an icon in the menu bar with three visible states — idle (`mic` SF Symbol), recording (`mic.fill` tinted red), transcribing (`waveform`). One menu item: "Quit Mumblur".
- Global push-to-talk hotkey, fixed in v1 to **Right Option**, via `CGEventTap` on `flagsChanged` events.
- 16 kHz mono mic capture via `AVAudioEngine` for the duration of the hold.
- Record-then-transcribe: on release, the buffer is handed to WhisperKit, then the result is pasted at the cursor via `NSPasteboard` + synthesized ⌘V.
- WhisperKit with a `large-v3-turbo` Core ML model, auto-downloaded on first launch.
- Multilingual auto-detect.
- macOS Accessibility and Microphone permissions handled via the OS-native dialogs (not custom UI).
- Locked state machine with worker dispatch — same single-flight semantics as Python (`idle → recording → transcribing → idle`; new presses during `transcribing` are rejected with a log line).

### Out of scope (v1)

- LoRA fine-tuning (deferred phase 2).
- Streaming transcription / partial results during hold.
- Voice Activity Detection.
- Configurable hotkey (Right Option only in v1; `KeyboardShortcuts` package added in v2 for user customization).
- Preferences window or any UI beyond the menu bar.
- launchd / Login Items / auto-start at login.
- Sparkle / TestFlight / auto-update.
- Code signing with a Developer ID certificate (ad-hoc is sufficient for single-user use).
- Notarization.
- Pasteboard restoration after paste.
- Telemetry, crash reporting, multi-user support.

### Non-goals

- Cross-platform support. macOS 13+ Apple Silicon only, Tahoe 26.x as primary target.
- Sub-100 ms latency. Same target as Python: "feels instant for short utterances."
- Reuse of any Python code at runtime. The Python implementation stays on disk as a reference; it is not invoked.

## 4. What carries over from the Python design

- **Architecture pattern**: five narrow components — Audio, Paste, Transcribe, Hotkey, Runner — wired by an app entry point.
- **State machine**: `idle / recording / transcribing`, locked, worker-thread dispatch for inference, single-flight rejection of presses during `transcribing`, min-hold-ms guard.
- **Test fixture**: `Tests/MumblurCoreTests/Fixtures/hello_world.wav` is the same `say`-generated 16 kHz mono WAV used in the Python tests.
- **Verification harness pattern**: per-task gate (`scripts/verify_task.sh N`) that ensures executions of the implementation plan work together. Adapted for Swift toolchain (`swift test` and `xcodebuild test`).
- **Specs/plans directory**: `docs/superpowers/{specs,plans}/` continues to host design and implementation docs.
- **Branching**: continue on `feat/mvp` for spec/plan commits; the Swift implementation lives on a new branch `feat/swift` cut from `master` so the Python prototype's code stays accessible on `feat/mvp` for reference.

## 5. Architecture

### 5.1 Process model

A single foreground macOS app (`Mumblur.app`) with `LSUIElement = true` in `Info.plist` (no Dock icon, menu bar only). `WhisperKit` is initialized once on app launch behind an `actor` and kept resident for the process lifetime. The hotkey listener runs on the main run loop via `CGEventTap`. Mic capture runs in `AVAudioEngine`'s internal real-time thread. Transcription + paste runs on a dedicated background `DispatchQueue` (the "worker"), keeping the main thread free for menu bar / event tap responsiveness.

### 5.2 Best-practice project layout

Two Swift modules — a thin app shell and a testable core package. This separation is the standard pattern for production Swift macOS apps (industry-popularized by Sindre Sorhus and adopted by most open-source menu bar apps). Benefits:

- The core compiles and tests in seconds with `swift test` — no Xcode project, no `xcodebuild` overhead.
- The core has zero AppKit/SwiftUI dependencies, so each unit can be reasoned about in isolation.
- The app target stays small and concrete: SwiftUI scenes + permission UX + lifecycle.

```
mumbler/                              # repo root (existing; keep name to preserve git history)
├── Mumblur.xcodeproj/                # Xcode project (NEW)
│
├── App/                              # Thin app target (NEW)
│   ├── MumblurApp.swift              # @main, SwiftUI MenuBarExtra
│   ├── MenuBarContent.swift          # SwiftUI view for the menu's drop-down
│   ├── AppCoordinator.swift          # owns Core types; bridges hotkey events → Runner
│   ├── PermissionsCoordinator.swift  # drives PermissionGate; opens System Settings on deny
│   └── Resources/
│       ├── Info.plist                # LSUIElement, NSMicrophoneUsageDescription,
│       │                             # NSAccessibilityUsageDescription
│       ├── Mumblur.entitlements      # hardened runtime opt-outs (audio input)
│       └── Assets.xcassets/          # menu bar icons (SF Symbol references)
│
├── MumblurCore/                      # Swift Package (NEW) — testable, no UI
│   ├── Package.swift
│   ├── Sources/MumblurCore/
│   │   ├── AudioRecorder.swift       # AVAudioEngine wrapper; protocol + concrete + fake
│   │   ├── Transcriber.swift         # WhisperKit actor; protocol + concrete + fake
│   │   ├── Paster.swift              # NSPasteboard + CGEvent paste; protocol + concrete + fake
│   │   ├── Hotkey.swift              # CGEventTap monitor + pure Dispatcher state machine
│   │   ├── Runner.swift              # locked state machine, worker dispatch
│   │   ├── PermissionGate.swift      # AXIsProcessTrusted + AVCaptureDevice auth wrappers
│   │   └── Logging.swift             # os.Logger("world.questable.mumblur") shared instances
│   └── Tests/MumblurCoreTests/
│       ├── AudioRecorderTests.swift
│       ├── PasterTests.swift
│       ├── TranscriberTests.swift    # unit tests + a `slow`-tagged integration test
│       ├── HotkeyTests.swift         # Dispatcher logic only
│       ├── RunnerTests.swift
│       └── Fixtures/
│           └── hello_world.wav       # reused from Python version
│
├── scripts/
│   ├── verify_task.sh                # MODIFIED — Swift toolchain
│   ├── build_app.sh                  # xcodebuild + ad-hoc sign for local install
│   └── (existing scripts retained for reference; not used by the Swift build)
│
└── docs/                             # KEPT — specs and plans
```

### 5.3 Module contracts (Swift)

Each Core module exposes a protocol + a concrete impl + a fake for tests. Protocols enable dependency injection in `Runner`, which is what makes the locked state machine independently testable.

**`AudioRecorder`**
```swift
public protocol AudioRecording: AnyObject {
    func start() throws
    func stop() -> [Float]
    func abortIfActive()
}

public final class AudioRecorder: AudioRecording {
    public init() throws         // configures AVAudioEngine; does not start
    public func start() throws   // installs tap, starts engine
    public func stop() -> [Float]
    public func abortIfActive()
}
```
- Always 16 kHz mono float32. If the input device's native rate differs, an `AVAudioConverter` resamples in the tap callback.
- Internally uses `inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in ... }`.
- `stop()` is synchronous and idempotent. Stop errors (e.g., device unplugged) are caught and converted to an empty `[Float]` — mirrors the Python `audio.py` behavior.

**`Paster`**
```swift
public protocol Pasting {
    func paste(_ text: String)
}

public struct Paster: Pasting {
    public init()
    public func paste(_ text: String)   // no-op on empty/whitespace
}
```
- Writes `text` to `NSPasteboard.general` (`clearContents()` then `setString(_:forType: .string)`).
- Synthesizes ⌘V via `CGEvent(keyboardEventSource:virtualKey:keyDown:)` for `kVK_ANSI_V` with the `.maskCommand` flag, posted to `CGEventTapLocation.cghidEventTap`.
- No subprocess shelling out to `pbcopy`.

**`Transcriber`**
```swift
public protocol Transcribing {
    func transcribe(_ samples: [Float]) async throws -> String
}

public actor Transcriber: Transcribing {
    public init(modelName: String, language: String?) async throws
    public func transcribe(_ samples: [Float]) async throws -> String
}
```
- `actor` so the WhisperKit instance is accessed serially; matches WhisperKit's recommended usage (init once, reuse).
- `language: nil` → auto-detect; otherwise BCP-47 / ISO 639-1 code.
- Empty input → empty string, model not invoked.

**`Hotkey`**
```swift
public enum HotkeyEvent { case press, release }

public protocol HotkeyListening: AnyObject {
    func start() throws       // installs CGEventTap; requires Accessibility
    func stop()
}

public final class Hotkey: HotkeyListening {
    public init(targetKeycode: CGKeyCode = 0x3D /* kVK_RightOption */,
                onEvent: @escaping @Sendable (HotkeyEvent) -> Void)
    public func start() throws
    public func stop()
}

/// Pure state machine, no AppKit involvement, unit-testable.
public struct HotkeyDispatcher {
    public init(targetKeycode: CGKeyCode,
                onPress: @escaping () -> Void,
                onRelease: @escaping () -> Void)
    public mutating func handle(keycode: CGKeyCode, isDown: Bool)
}
```
- Watches `.flagsChanged` events on `kCGSessionEventTap`. The event delivers the new flag state; the dispatcher diffs against the previously-seen state to emit press/release for the target keycode.
- Right Option = `kVK_RightOption` (0x3D); distinguished from Left Option (`kVK_Option`, 0x3A) by `event.getIntegerValueField(.keyboardEventKeycode)`.
- `onEvent` is `@Sendable` because it fires on the event tap thread; consumers hop to their own queue as needed.

**`Runner`**
```swift
public final class Runner {
    public enum State: String, Sendable { case idle, recording, transcribing }

    public init(recorder: AudioRecording,
                transcriber: Transcribing,
                paster: Pasting,
                minHoldMs: Int = 200,
                worker: DispatchQueue,
                clock: @escaping @Sendable () -> Date = Date.init,
                onStateChange: @escaping @Sendable (State) -> Void = { _ in })

    public var state: State { get }   // thread-safe via lock
    public func onPress()             // call from event tap thread
    public func onRelease()
    public func shutdown()            // abort recording; safe to call twice
}
```
- Internal `os_unfair_lock` (wrapped in a small `Mutex` helper) guards state transitions and `pressTime`.
- `onRelease` dispatches the transcribe-and-paste pipeline to `worker` and returns immediately. The dispatch is what makes "press during transcription is ignored" a real, observable behavior.
- `onStateChange` callback fires whenever state transitions; the app uses it to update the menu bar icon (hopped to `MainActor`).

**`PermissionGate`**
```swift
public enum PermissionResult: Sendable { case granted, denied, prompted }

public enum PermissionGate {
    /// Triggers the OS dialog if `prompt` is true and the process is not yet trusted.
    public static func ensureAccessibility(prompt: Bool) -> PermissionResult

    /// Triggers AVCaptureDevice.requestAccess(.audio).
    public static func ensureMicrophone() async -> PermissionResult
}
```
- Accessibility check uses `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true as CFBoolean])`.
- Microphone check uses `AVCaptureDevice.requestAccess(for: .audio)` — pops the dialog with `NSMicrophoneUsageDescription` from `Info.plist`.

**`MumblurApp` (app target)**
```swift
@main
struct MumblurApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coordinator: coordinator)
        } label: {
            Image(systemName: coordinator.icon)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.menu)
    }
}
```
- `AppCoordinator` is an `@MainActor` `ObservableObject` that owns the `Hotkey`, `Runner`, `AudioRecorder`, `Transcriber`, `Paster`, and exposes `@Published` `state` and `icon` for the SwiftUI view.

### 5.4 Data flow

```
[Mumblur.app launch — MainActor]
   await PermissionGate.ensureMicrophone()        ▸ AVCaptureDevice prompt
   PermissionGate.ensureAccessibility(prompt: true) ▸ AXIsProcessTrusted prompt
   transcriber = try await Transcriber(modelName: "large-v3-turbo", language: nil)
   recorder    = try AudioRecorder()
   runner      = Runner(recorder, transcriber, paster, minHoldMs: 200,
                        worker: .global(qos: .userInitiated),
                        onStateChange: { state in
                            DispatchQueue.main.async { coordinator.applyState(state) }
                        })
   hotkey      = Hotkey { event in
                    switch event {
                    case .press:   runner.onPress()
                    case .release: runner.onRelease()
                    }
                 }
   try hotkey.start()

[Right Option pressed — event tap thread]
   hotkey emits .press → runner.onPress()
     ▸ lock → state was idle → state = recording → unlock
     ▸ try? recorder.start()
     ▸ onStateChange(.recording) → MenuBar icon → mic.fill

[Right Option released — event tap thread]
   hotkey emits .release → runner.onRelease()
     ▸ lock → state was recording → unlock
     ▸ samples = recorder.stop()
     ▸ if heldMs < minHoldMs: lock → state = idle → unlock; menubar icon → mic
     ▸ lock → state = transcribing → unlock; menubar icon → waveform
     ▸ worker.async { runner.doWork(samples) }

[Worker queue]
   doWork(samples) {
     do {
       let text = try await transcriber.transcribe(samples)
       if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
           paster.paste(text)
       }
     } catch {
       logger.error("transcription failed: \(error)")
     }
     lock → state = idle → unlock; menubar icon → mic
   }
```

### 5.5 Permission flow

The crucial difference from the Python version. Because `Mumblur.app` is a signed bundle:

1. On first launch, `PermissionGate.ensureMicrophone()` triggers `AVCaptureDevice.requestAccess(.audio)`. macOS reads `NSMicrophoneUsageDescription` from `Info.plist` and presents the official dialog. User clicks Allow.
2. `PermissionGate.ensureAccessibility(prompt: true)` calls `AXIsProcessTrustedWithOptions` with the prompt option. macOS shows the standard dialog with an "Open System Settings" button → user toggles Mumblur **ON** in Privacy & Security → Accessibility. The entry is created automatically because the prompt was triggered.
3. After both grants, `hotkey.start()` succeeds.
4. If either grant is denied, the menu bar shows a small warning badge on the icon, and the drop-down has a "Grant Permissions…" item that re-runs `PermissionGate` (which will re-prompt or deep-link to System Settings via `NSWorkspace`).

This works because the requesting identity is a stable `.app` bundle tracked by `CFBundleIdentifier` + cdhash. The toggle stays on, doesn't drift across updates, doesn't depend on which terminal launched anything.

## 6. WhisperKit integration

- Package: `https://github.com/argmaxinc/argmax-oss-swift` (SwiftPM dependency on `MumblurCore`).
- Import: `import WhisperKit`.
- Model: a `large-v3-turbo` Core ML variant from `argmaxinc/whisperkit-coreml`. The exact identifier (`large-v3-turbo` vs `openai_whisper-large-v3-v20240930_turbo` etc.) is verified at plan-stage by enumerating the published list; if the canonical name isn't found, `Transcriber.init` falls back to `large-v3` and logs a warning.
- Storage: WhisperKit caches into its default location (`~/Library/Application Support/<app-bundle-id>/`).
- Inference: `try await whisperKit.transcribe(audioArray: samples)?.first?.text ?? ""`. The API also accepts file paths and other shapes; we use the in-memory `[Float]` path.
- Multilingual: `DecodingOptions(language: nil, task: .transcribe, ...)` — pass `nil` for auto-detect. Exact field name and default values confirmed in plan stage.
- Initialization is `async` and slow (~1–3 s) because it downloads / mmaps the Core ML model. The app shows a "Loading model…" menu bar state during this period.

## 7. Build, signing, and distribution

- `xcodebuild -project Mumblur.xcodeproj -scheme Mumblur -configuration Release` produces `build/Release/Mumblur.app`.
- Ad-hoc sign with `codesign --force --deep --sign - --options runtime Mumblur.app`. Tahoe honors ad-hoc signatures on `.app` bundles (unlike for bare CLI binaries) because the bundle has a stable cdhash + `CFBundleIdentifier`.
- Install: copy to `/Applications/Mumblur.app`.
- `scripts/build_app.sh` wraps build + sign + (optionally) copy-to-/Applications for one-command iteration.
- No notarization, no Developer ID needed for single-user use.

## 8. Verification harness

`scripts/verify_task.sh` adapted for the Swift toolchain. Each task ends with `scripts/verify_task.sh N`. The harness checks (per task):

- File-existence (xcodeproj parts, source files, Info.plist keys present).
- `cd MumblurCore && swift build` — confirms the core package compiles.
- `cd MumblurCore && swift test --filter '!Slow'` — fast unit tests.
- `xcodebuild build -scheme Mumblur -destination 'platform=macOS' -quiet` — confirms the app target compiles.
- For tasks past app-shell completion: `codesign -dv build/Debug/Mumblur.app | grep Identifier` confirms the bundle has a stable identity.

A fresh subagent picking up Task N can run `scripts/verify_task.sh N-1` first to confirm the world matches what Task N expects. Same pattern as the Python version.

## 9. Testing strategy

XCTest target inside `MumblurCore` (not the app target):

- **`AudioRecorderTests`** — inject a fake `AVAudioFormat` + synthesized buffers; verify resampling output, accumulation order, and that `stop()` returns the concatenated samples in float32.
- **`PasterTests`** — `paste("hello")` then read back via `NSPasteboard.general.string(forType: .string)`. The ⌘V keystroke assertion is omitted (no active app in tests); a comment documents the gap.
- **`TranscriberTests`** — unit tests with a fake `WhisperKitProtocol` (we wrap `WhisperKit` in our own protocol so it can be faked); a `Slow`-tagged integration test loads the real model and transcribes `hello_world.wav`. Slow tests excluded by `swift test --filter '!Slow'`.
- **`HotkeyTests`** — exercise `HotkeyDispatcher` only: target-key vs other-key, isDown transitions, repeated identical states are not duplicated. The actual `CGEventTap` install path is exercised by manual smoke test in Task N (TBD in plan).
- **`RunnerTests`** — inject all dependencies as fakes; verify state transitions (idle → recording → transcribing → idle), single-flight rejection (deferred worker pattern from Python), min-hold discard, exception handling, shutdown idempotency.

## 10. Logging

`Logging.swift` exposes shared `os.Logger` instances per module:

```swift
import os

extension Logger {
    static let app        = Logger(subsystem: "world.questable.mumblur", category: "app")
    static let hotkey     = Logger(subsystem: "world.questable.mumblur", category: "hotkey")
    static let audio      = Logger(subsystem: "world.questable.mumblur", category: "audio")
    static let transcribe = Logger(subsystem: "world.questable.mumblur", category: "transcribe")
    static let paste      = Logger(subsystem: "world.questable.mumblur", category: "paste")
    static let runner     = Logger(subsystem: "world.questable.mumblur", category: "runner")
}
```

Errors and lifecycle events go through `Logger`. `print` and `NSLog` are not used. Live log inspection via `log stream --predicate 'subsystem == "world.questable.mumblur"'`.

## 11. Concurrency model

- Swift 6 strict concurrency target.
- `@MainActor`: `AppCoordinator`, all SwiftUI views, `applyState`.
- `actor`: `Transcriber`.
- `os_unfair_lock` (via a `Mutex<T>` helper struct): inside `Runner` for its tiny state machine. Why not an actor: actors serialize via async hops, which would force `onPress`/`onRelease` to become `async` and complicate the event-tap callback chain. The lock is held for nanoseconds around a state read/write — far simpler than the actor alternative.
- `Sendable` annotations on all callback closures crossing concurrency domains.
- `DispatchQueue.global(qos: .userInitiated)` for the transcription worker.

## 12. Open questions (deferred to plan, not blocking)

1. **Exact WhisperKit model identifier for large-v3-turbo.** Resolved at plan stage by enumerating models in `argmaxinc/whisperkit-coreml` and picking the canonical large-v3 turbo variant.
2. **WhisperKit `DecodingOptions` API field names.** Confirmed by reading argmax's source / current README during plan stage.
3. **Right Option detection on dvorak / non-US layouts.** `kVK_RightOption` is physical, not layout-dependent, so this should not be an issue. Verify during manual smoke test.
4. **Menu bar icon animation during transcribing.** Static SF Symbol vs SwiftUI `.symbolEffect(.variableColor.iterative)`. Plan picks one.
5. **App sandbox.** Enabling the App Sandbox would tighten security but require additional entitlements (audio input, network for model download). For a personal-use ad-hoc-signed app we can ship un-sandboxed. Decision deferred to plan; default is un-sandboxed for v1.

## 13. Definition of Done

- `Mumblur.app` builds via `scripts/build_app.sh` and installs to `/Applications/`.
- First launch prompts for Microphone and Accessibility via OS-native dialogs; both grants persist across reboot.
- Holding Right Option for ≥ 200 ms while speaking, then releasing, pastes the transcript at the cursor in any focused app within roughly decode time (≤ 1 s for short utterances on M3 Max).
- Menu bar icon visibly transitions between idle / recording / transcribing.
- Pressing Right Option during a transcription is rejected; log shows the rejection; the in-flight transcription completes and pastes.
- `swift test --filter '!Slow'` from `MumblurCore/` passes (all fast unit tests).
- `swift test --filter Slow` passes once on the dev machine (real-model integration test).
- `xcodebuild build -scheme Mumblur` succeeds with no warnings beyond unavoidable WhisperKit warnings.
- `scripts/verify_task.sh N` (for the final N) passes.
- The Python implementation on `feat/mvp` is left intact as a reference; the Swift implementation lives on `feat/swift`.
