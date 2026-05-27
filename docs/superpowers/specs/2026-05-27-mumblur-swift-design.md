# Mumblur — Swift Rewrite (Menu-Bar Push-to-Talk Dictation)

**Status:** Design proposed, pending approval
**Date:** 2026-05-27
**Target machine:** Apple Silicon (M3 Max, macOS Tahoe 26.x), single user
**Supersedes:** `2026-05-27-push-to-talk-dictation-design.md` (Python version) and any earlier Swift drafts

Project rename: the Python prototype was called `mumbler`; the Swift rewrite is **`mumblur`**. Bundle identifier: `world.questable.mumblur`.

## 1. Why a rewrite

The Python prototype works end-to-end (24 passing tests, slow integration test transcribes the fixture in ~25 s). It fails at the last mile on macOS Tahoe 26.x because the OS will not honor Accessibility grants for ad-hoc-signed CLI binaries running under terminals — Homebrew Python, Homebrew-cask Alacritty, and pyenv-built Python all fail `AXIsProcessTrusted()` even with the toggle visibly on.

This is a stack mismatch, not a coding bug. macOS' permission model expects `.app` bundles with stable identities. Repackaging the Python as a signed `.app` (via `py2app` or `briefcase`) would work but adds non-trivial build/signing infrastructure for something Swift solves natively.

The rewrite is therefore a port, not a redesign: the architecture (five small modules with narrow contracts, locked state machine, single-flight worker, record-then-transcribe semantics) carries over verbatim. Only the implementation language and platform APIs change.

## 2. Goal

A local push-to-talk dictation tool for macOS Apple Silicon, distributed as `Mumblur.app`. The user holds **Right Option** while speaking; on release, the recorded audio is transcribed locally and pasted at the cursor in the active app. Everything runs on-device. No network calls at runtime (model download is one-time, on first launch).

## 3. Scope & platform

### Platform requirements

- **macOS 14.0+ (Sonoma)** — driven by WhisperKit's minimum (`argmaxinc/argmax-oss-swift` README).
- **Xcode 16.0+** — required by WhisperKit's current major version.
- **Swift 6** with strict concurrency on (we'll narrow specific exemptions where WhisperKit isn't yet `Sendable`).
- Apple Silicon. Primary target is M3 Max on Tahoe 26.x.

### In scope (v1)

- A single `Mumblur.app` bundle (ad-hoc signed for personal dev iteration; Developer ID added later if/when distributing).
- **SwiftUI `MenuBarExtra`** UI: an icon in the menu bar with state-driven SF Symbol — idle (`mic`), recording (`mic.fill`, red tint), transcribing (`waveform`), or warning (`exclamationmark.triangle`) when permissions are missing. The drop-down has "Grant Permissions…" (visible only if needed) and "Quit Mumblur".
- Global push-to-talk hotkey, fixed in v1 to **Right Option**, via `CGEventTap` on `flagsChanged` events.
- 16 kHz mono mic capture via `AVAudioEngine` for the duration of the hold.
- Record-then-transcribe: on release, the buffer is handed to WhisperKit, then the result is pasted at the cursor via `NSPasteboard` + a synthesized ⌘V `CGEvent`.
- WhisperKit with a `large-v3-turbo` Core ML model from `argmaxinc/whisperkit-coreml`, auto-downloaded on first launch.
- Multilingual auto-detect (`DecodingOptions(language: nil, detectLanguage: true, usePrefillPrompt: true)`).
- OS-native permission prompts for Microphone, Accessibility, **and Input Monitoring** (required by `CGEventTap` on macOS 14+). Menu bar reflects permission state and offers a one-click open-System-Settings shortcut when any grant is missing. A mandatory 2 s re-check timer fires while any permission is denied.
- Locked state machine with single-flight semantics — `idle → recording → stopping → transcribing → idle` — and a `Task`-based pipeline for transcribe + paste so the state machine, not GCD, provides the single-flight gate.

### Out of scope (v1)

- LoRA fine-tuning (deferred phase 2).
- Streaming transcription / partial results during hold.
- Voice Activity Detection.
- Configurable hotkey (Right Option only in v1; `KeyboardShortcuts` package added in v2 for user customization).
- Preferences window or any UI beyond the menu bar drop-down.
- launchd / Login Items / auto-start at login.
- Sparkle / TestFlight / auto-update.
- Code signing with a Developer ID certificate (ad-hoc is sufficient for single-user use).
- Notarization.
- Pasteboard restoration after paste.
- Telemetry, crash reporting, multi-user support.

### Non-goals

- Cross-platform support. macOS 14+ Apple Silicon only, Tahoe 26.x as primary target.
- Sub-100 ms latency. Same target as Python: "feels instant for short utterances."
- Reuse of any Python code at runtime. The Python implementation stays on disk as a reference; it is not invoked.

## 4. What carries over from the Python design

- **Architecture pattern**: five narrow components — Audio, Paste, Transcribe, Hotkey, Runner — wired by an app coordinator.
- **State machine**: `idle / recording / stopping / transcribing`, locked, single-flight rejection of presses while not `idle`, min-hold-ms guard.
- **Test fixture**: `Tests/MumblurCoreTests/Fixtures/hello_world.wav` is the same `say`-generated 16 kHz mono WAV used in the Python tests.
- **Verification harness pattern**: per-task gate (`scripts/verify_task.sh N`) that ensures executions of the implementation plan work together. Adapted for Swift toolchain (`swift test` and `xcodebuild test`).
- **Specs/plans directory**: `docs/superpowers/{specs,plans}/` continues to host design and implementation docs.
- **Branching**: spec/plan commits continue on `feat/mvp`; the Swift implementation lives on a new branch `feat/swift` cut from `master` so the Python prototype's code stays accessible on `feat/mvp` for reference.

## 5. Architecture

### 5.1 Process model

A single foreground macOS app (`Mumblur.app`) with `LSUIElement = true` in `Info.plist` (no Dock icon, menu bar only). `WhisperKit` is initialized once on app launch behind an `actor` and kept resident for the process lifetime. The hotkey listener runs via `CGEventTap` installed on the main thread's run loop. Mic capture runs in `AVAudioEngine`'s real-time audio thread. Transcription + paste runs in a structured `Task` spawned by `Runner.onRelease`; the `Task` is the unit the state machine tracks for single-flight, *not* a GCD queue.

### 5.2 Project layout (best-practice fit)

Two Swift modules — a thin app shell and a testable core package. This separation is the standard pattern for production Swift macOS apps: the core compiles and tests in seconds with `swift test`, has **no SwiftUI and no app-lifecycle code**, and each unit is reasoned about in isolation. (The core does depend on AppKit-level APIs such as `NSPasteboard` and `AVFoundation`; "no AppKit" would be wrong to claim. The contract is "no UI scenes, no `@main`, no `NSApplication`/`MenuBarExtra` references" — testable units only.)

```
mumbler/                              # repo root (keep name to preserve git history)
├── Mumblur.xcodeproj/                # Xcode project (NEW)
│
├── App/                              # Thin app target (NEW)
│   ├── MumblurApp.swift              # @main, SwiftUI MenuBarExtra
│   ├── MenuBarContent.swift          # SwiftUI view for the menu's drop-down
│   ├── AppCoordinator.swift          # @MainActor; owns Core types; bridges events → Runner
│   ├── PermissionsCoordinator.swift  # drives PermissionGate; deep-links to System Settings
│   └── Resources/
│       ├── Info.plist                # LSUIElement, NSMicrophoneUsageDescription
│       ├── Mumblur.entitlements      # hardened runtime + com.apple.security.device.audio-input
│       └── Assets.xcassets/          # menu bar icon set (SF Symbols)
│
├── MumblurCore/                      # Swift Package (NEW) — testable, no UI
│   ├── Package.swift
│   ├── Sources/MumblurCore/
│   │   ├── AudioRecorder.swift       # AVAudioEngine wrapper; protocol + concrete + fake
│   │   ├── Transcriber.swift         # WhisperKit actor; protocol + concrete + fake
│   │   ├── Paster.swift              # NSPasteboard + CGEvent paste; protocol + concrete + fake
│   │   ├── Hotkey.swift              # CGEventTap monitor + pure Dispatcher state machine
│   │   ├── Runner.swift              # locked state machine, Task-based pipeline
│   │   ├── PermissionGate.swift      # AXIsProcessTrusted + AVCaptureDevice auth wrappers
│   │   └── Logging.swift             # os.Logger("world.questable.mumblur") shared instances
│   └── Tests/MumblurCoreTests/
│       ├── AudioRecorderTests.swift
│       ├── PasterTests.swift
│       ├── TranscriberTests.swift    # unit tests + a `slow`-tagged integration test
│       ├── HotkeyTests.swift         # HotkeyDispatcher logic only
│       ├── RunnerTests.swift
│       └── Fixtures/
│           └── hello_world.wav       # reused from Python version
│
├── scripts/
│   ├── verify_task.sh                # MODIFIED — Swift toolchain
│   ├── build_app.sh                  # xcodebuild + (Xcode-driven ad-hoc) sign for local install
│   └── (existing Python scripts retained for reference; not used by the Swift build)
│
└── docs/                             # KEPT — specs and plans
```

`NSAccessibilityUsageDescription` is intentionally absent — Apple does not document this plist key; Accessibility trust is driven entirely by `AXIsProcessTrustedWithOptions`, not by a usage-description string.

### 5.3 Module contracts (Swift)

Each Core module exposes a protocol + a concrete impl + a fake for tests. Protocols enable dependency injection in `Runner`, which is what makes the locked state machine independently testable.

**`AudioRecorder`**
```swift
public protocol AudioRecording: AnyObject, Sendable {
    func start() throws
    func stop() -> [Float]
    func abortIfActive()
}

public final class AudioRecorder: AudioRecording, @unchecked Sendable {
    public init() throws         // configures AVAudioEngine; does not start
    public func start() throws   // installs tap, starts engine
    public func stop() -> [Float]
    public func abortIfActive()
}
```
- Always 16 kHz mono float32. If the input device's native rate differs, an `AVAudioConverter` resamples in the tap callback.
- Internally uses `inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in ... }`. Buffer pushes into an array guarded by a small lock (real-time thread; lock is held for a fraction of a millisecond).
- `stop()` is synchronous and idempotent. Stop errors (e.g., device unplugged) are caught and converted to an empty `[Float]` — mirrors the Python `audio.py` behavior.
- `@unchecked Sendable` is honest about why we're claiming Sendable: the type internally uses a lock to protect mutable state; the compiler can't see that.

**`Paster`**
```swift
public protocol Pasting: Sendable {
    func paste(_ text: String) async   // async because AppKit hop is required
}

@MainActor
public struct Paster: Pasting {
    public init()
    public func paste(_ text: String)   // synchronous on MainActor; protocol awaits it
}
```
- `@MainActor`-isolated: `NSPasteboard` is AppKit, which Apple's thread-safety docs do not declare broadly safe for background use. Pasteboard reads/writes and synthesized events conventionally run on main.
- Writes `text` to `NSPasteboard.general` (`clearContents()` then `setString(_:forType: .string)`).
- Synthesizes ⌘V via `CGEvent(keyboardEventSource:virtualKey:keyDown:)` for `kVK_ANSI_V` with `.maskCommand`, posted to `CGEventTapLocation.cghidEventTap`.
- The worker awaits the `MainActor`-isolated call; this is a small, cheap hop.

**`Transcriber`**
```swift
public protocol Transcribing: Sendable {
    func transcribe(_ samples: [Float]) async throws -> String
}

public actor Transcriber: Transcribing {
    public init(modelName: String, language: String?) async throws
    public func transcribe(_ samples: [Float]) async throws -> String
}
```
- `actor` so the WhisperKit instance is accessed serially. This is what we lean on instead of expecting WhisperKit itself to be `Sendable` (it isn't yet in v1.0).
- `language: nil` → auto-detect; otherwise BCP-47 / ISO 639-1 code.
- Empty input → empty string, model not invoked.

**`Hotkey`**
```swift
public enum HotkeyEvent: Sendable { case press, release }

public protocol HotkeyListening: AnyObject, Sendable {
    func start() throws        // installs CGEventTap; requires Accessibility
    func stop()
}

public final class Hotkey: HotkeyListening, @unchecked Sendable {
    public init(targetKeycode: CGKeyCode = 0x3D /* kVK_RightOption */,
                onEvent: @escaping @Sendable (HotkeyEvent) -> Void)
    public func start() throws
    public func stop()
}

/// Pure state machine, no AppKit involvement, unit-testable.
public struct HotkeyDispatcher: Sendable {
    public init(targetKeycode: CGKeyCode,
                onPress: @escaping @Sendable () -> Void,
                onRelease: @escaping @Sendable () -> Void)
    /// Call once per .flagsChanged event whose keycode matches `targetKeycode`.
    /// The dispatcher toggles internal down-state and emits the right callback.
    public mutating func handle(keycode: CGKeyCode)
}
```

**Detection algorithm** (treat as Tahoe-empirical, smoke-test required):
- Install on `kCGSessionEventTap`, watching `CGEventMask(1 << CGEventType.flagsChanged.rawValue)`.
- For each event: check `event.type == .flagsChanged`; read keycode via `event.getIntegerValueField(.keyboardEventKeycode)`.
- The dispatcher maintains a `Set<CGKeyCode>` of currently-down modifier keys. Each `flagsChanged` event for a tracked keycode **toggles** that key's membership in the set: if the keycode was not present → emit `press` and insert; if it was present → emit `release` and remove.
- We do **not** use `event.flags.contains(.maskAlternate)` to decide press vs release: that aggregate flag reflects "any Option key down" and cannot distinguish Right Option from Left Option. With Left Option already held, a Right Option transition would not flip the aggregate bit. Per-keycode toggle tracking is the only reliable approach.
- Note: `keyboardEventKeycode` on `flagsChanged` is empirically correct on every macOS version we've tested but is not formally documented for this event type. Manual smoke test on Tahoe — including a "Left Option held, then Right Option tapped" scenario — is a required Definition-of-Done item.

**`Runner`**
```swift
public final class Runner: @unchecked Sendable {
    public enum State: String, Sendable {
        case idle, recording, stopping, transcribing
    }

    public init(recorder: AudioRecording,
                transcriber: Transcribing,
                paster: Pasting,
                minHoldMs: Int = 200,
                clock: @escaping @Sendable () -> Date = Date.init,
                onStateChange: @escaping @Sendable (State) -> Void = { _ in })

    public var state: State { get }   // thread-safe via OSAllocatedUnfairLock
    public func onPress()             // call from event-tap thread
    public func onRelease()           // call from event-tap thread
    public func shutdown()            // abort recording; safe to call twice
}
```

- Internal `OSAllocatedUnfairLock<MutableState>` (Swift-safe replacement for raw `os_unfair_lock`) guards a small struct:
  ```swift
  private struct MutableState {
      var state: State = .idle
      var pressTime: Date = .distantPast
      var worker: Task<Void, Never>? = nil
  }
  ```
- `onRelease` immediately transitions `recording → stopping` *and* captures `pressTime` while still holding the lock, before calling `recorder.stop()`. This closes the TOCTOU window and respects the lock invariant: `pressTime` is read inside the same critical section that transitions out of `.recording`.
- After `stop()` and the min-hold check (using the snapshotted `pressTime`), transition `stopping → idle` (short press) or `stopping → transcribing`. The `transcribing` state is entered *before* the `Task` is spawned, and only the worker task can transition out of it.
- The worker task is created via `Task.detached(priority: .userInitiated)` to avoid inheriting the caller's actor context, and its handle is stored in `MutableState.worker` so `shutdown()` can `cancel()` it. Inside the worker, the paste step checks `Task.isCancelled` before pasting; a cancelled worker skips paste and still transitions back to `.idle`.
- Single-flight is enforced by the state machine (`onPress` rejects anything not `.idle`), not by GCD serialization.

**`PermissionGate`**
```swift
public enum PermissionResult: Sendable { case granted, denied, prompted }

public enum PermissionGate {
    /// Returns the *current* Accessibility trust state. If `prompt` is true and trust
    /// is missing, also triggers macOS' Accessibility dialog (async — the user grants
    /// after this call returns).
    public static func ensureAccessibility(prompt: Bool) -> PermissionResult

    /// Returns the *current* Input Monitoring trust state. If `prompt` is true and
    /// the state is `.notDetermined`, triggers `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`
    /// which causes macOS to add the app to Input Monitoring and pop a dialog. Like
    /// Accessibility, this is async and we must re-check.
    public static func ensureInputMonitoring(prompt: Bool) -> PermissionResult

    /// Async — pops AVCaptureDevice's mic dialog and awaits the user's choice.
    public static func ensureMicrophone() async -> PermissionResult
}
```

Important Apple-documented behavior: `AXIsProcessTrustedWithOptions(...)` and `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` both return the *current* trust state immediately. Passing the prompt option triggers macOS' dialog as a side effect, but the return value does *not* reflect the user's eventual choice. Consequence (used in §5.5):

- We cannot wait for the call to "become true" in the same code path.
- We must re-check trust via a **mandatory 2 s repeating timer** (not just activation events — see §5.5) and start the event tap once both Accessibility *and* Input Monitoring transition to granted.

### 5.4 Data flow

```
[Mumblur.app launch — MainActor]
   await PermissionGate.ensureMicrophone()                       ▸ AVCaptureDevice prompt
   accTrust  = PermissionGate.ensureAccessibility(prompt: true)
   imTrust   = PermissionGate.ensureInputMonitoring(prompt: true)
   transcriber = try await Transcriber(modelName: resolvedModelName, language: nil)
   recorder    = try AudioRecorder()
   runner      = Runner(recorder, transcriber, paster, minHoldMs: 200,
                        onStateChange: { state in
                            Task { @MainActor in coordinator.applyState(state) }
                        })
   hotkey      = Hotkey { event in
                    switch event {
                    case .press:   runner.onPress()
                    case .release: runner.onRelease()
                    }
                 }
   if accTrust == .granted && imTrust == .granted {
       try hotkey.start()
   } else {
       coordinator.showPermissionWarning()
       startPermissionPollTimer()   // mandatory 2 s repeating; not just activation events
   }

[Right Option pressed — event tap thread]
   hotkey emits .press → runner.onPress()
     ▸ lock { if state != .idle, log+return; state = .recording; pressTime = clock() }
     ▸ try? recorder.start()
     ▸ onStateChange(.recording)  → menu bar icon hops to MainActor → mic.fill

[Right Option released — event tap thread]
   hotkey emits .release → runner.onRelease()
     ▸ snapshot = lock { (s: State, t: Date) in
                     guard state == .recording else { return nil }
                     state = .stopping             // closes TOCTOU
                     return (state: .stopping, pressTime: pressTime)
                  }
     ▸ guard snapshot != nil else { return }
     ▸ samples = recorder.stop()
     ▸ heldMs  = (clock() - snapshot.pressTime).milliseconds
     ▸ if heldMs < minHoldMs:
         lock { state = .idle }
         onStateChange(.idle); return
     ▸ lock { state = .transcribing }
     ▸ onStateChange(.transcribing)   // fire BEFORE spawn so doWork's later .idle is always observed second
     ▸ task = Task.detached(priority: .userInitiated) { await runner.doWork(samples) }
     // doWork may run and complete before we store the handle below.
     // If it already transitioned state back to .idle, don't overwrite —
     // cancel the (already-finished) task as a no-op and leave state alone.
     ▸ shouldCancel = lock {
           guard state == .transcribing else { return true }
           worker = task
           return false
       }
     ▸ if shouldCancel { task.cancel() }  // no extra onStateChange; doWork already emitted .idle

[Worker task — detached Task]
   doWork(samples) async {
     defer {
       lock { state = .idle; worker = nil }
       onStateChange(.idle)
     }
     do {
       let text = try await transcriber.transcribe(samples)
       guard !Task.isCancelled,
             !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
       else { return }
       await paster.paste(text)         // hops to MainActor (Paster is @MainActor)
     } catch is CancellationError {
       Logger.runner.debug("worker cancelled")
     } catch {
       Logger.transcribe.error("transcription failed: \(error)")
     }
   }
```

**State machine guarantees:**
- `onPress` accepts only when state is `idle`.
- A press during `recording`, `stopping`, or `transcribing` is logged and rejected.
- `stopping` is the intermediate state that closes the window between "user released the key" and "transcription is queued."
- `Task.detached` is used so the worker doesn't inherit the listener's actor context. State machine, not the Task lifecycle, provides single-flight.

### 5.5 Permission flow

The fundamental difference from the Python version. Because `Mumblur.app` is a signed bundle with a stable identity, TCC can track it reliably. Three permissions are required:

1. **Microphone** (`NSMicrophoneUsageDescription` in `Info.plist`) — sync, awaits user. `await PermissionGate.ensureMicrophone()` calls `AVCaptureDevice.requestAccess(for: .audio)`; macOS presents the dialog and the call awaits the user's choice.

2. **Accessibility** — async, fire-and-forget prompt. `PermissionGate.ensureAccessibility(prompt: true)` calls `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: kCFBooleanTrue])`. The prompt fires; the call returns the *current* (pre-grant) trust state immediately. Needed for `CGEventTap` and for synthesizing ⌘V.

3. **Input Monitoring** — async, fire-and-forget prompt. `PermissionGate.ensureInputMonitoring(prompt: true)` calls `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` if state is `.notDetermined`, then `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`. Returns the current state. **Required on macOS 14+ for global keyboard event monitoring**, in addition to Accessibility. (Accessibility alone is necessary but not sufficient for `CGEventTap` watching keyboard events on modern macOS.)

#### Decision tree

- If all three granted on launch: start the event tap, hide any warning UI.
- If any denied (the realistic "not yet granted" state for first launch): show a warning badge on the menu bar icon; menu drop-down shows a "Grant Permissions…" item that re-runs the prompts and deep-links to the right System Settings pane via `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_<Pane>")!)`. Pane names: `Privacy_Accessibility`, `Privacy_ListenEvent` (Input Monitoring), `Privacy_Microphone`.

#### Re-check loop (mandatory 2 s repeating timer)

We **cannot** rely on `NSApplication.didBecomeActiveNotification` alone: `Mumblur.app` is `LSUIElement = true`, so it does not become "active" in the normal sense when the user returns from System Settings (they were never in another regular app — they were in System Settings, then back to whatever they were in before, and Mumblur is just a menu bar item that doesn't get activated). The activation notification fires inconsistently for menu-bar-only apps.

Mandatory pattern: while any permission is denied, run a `Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true)`. Each tick re-checks all three permissions *without* prompting. On the first tick where all three are granted: call `hotkey.start()`, hide the warning, invalidate the timer. Activation observation is added as a *supplementary* trigger (it speeds up the happy case) but is not load-bearing.

This design tolerates the OS dialog's async nature regardless of whether the user returns to Mumblur through a "real" activation.

### 5.6 Ad-hoc signing and dev-iteration friction

Ad-hoc signatures identify *exactly* the one program being signed (Apple's Code Signing Guide). cdhash is content-addressed over the bundle; **every rebuild produces a different cdhash unless the build is fully reproducible**. Consequence for development:

- TCC tracks grants by cdhash for ad-hoc-signed apps. A rebuild creates a "different" app from TCC's perspective.
- Realistically, after every `xcodebuild` of `Mumblur.app`, you may have to re-grant Accessibility once.
- **Within a single build** (same cdhash, same install), the Accessibility grant is stable across reboots — that part is fine, and is the relevant property for actual use.
- For dev iteration, two mitigations:
  1. Keep the dev cycle on `~/Library/Developer/Xcode/DerivedData/.../Mumblur.app` — same path may help TCC's heuristic associate consecutive builds.
  2. Switch to a Developer ID signing identity if/when this friction becomes too costly. With Developer ID, TCC tracks by identity, not cdhash — grant persists across rebuilds.

Spec commitment: "permission grant persists for the installed app bundle on the dev machine and survives reboots." We do *not* claim survival across rebuilds.

## 6. WhisperKit integration

Verified against argmax-oss-swift v1.0+:

- Package: `https://github.com/argmaxinc/argmax-oss-swift` (SwiftPM dependency on `MumblurCore`).
- Import: `import WhisperKit`.
- Init: `WhisperKit(WhisperKitConfig(model: resolvedModelName))`. `resolvedModelName` is determined at runtime by calling `WhisperKit.fetchAvailableModels()` (or, if too slow on cold launch, by pinning a known-current identifier and validating). Argmax's published identifiers are date-suffixed and turbo-suffixed — current shape as of 2026-05 is `openai_whisper-large-v3-v20240930_turbo_632MB` on `argmaxinc/whisperkit-coreml`. The plan stage will pin the exact name. The string `"large-v3-turbo"` is **not** a valid published identifier and must not be used as-is.
- Fallback chain if the preferred turbo identifier cannot be resolved: try `"large-v3"` family, log a warning, continue.
- Inference:
  ```swift
  let options = DecodingOptions(
      language: nil,
      detectLanguage: true,
      usePrefillPrompt: true
  )
  let results = try await whisperKit.transcribe(audioArray: samples,
                                                 decodeOptions: options)
  let text = results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
  ```
  (Exact return shape — `[TranscriptionResult]` vs `TranscriptionResult` — confirmed in plan stage against current `WhisperKit.swift`.)
- Storage: WhisperKit caches into its default location, scoped to the app's container directory.
- Sendability: WhisperKit's top-level types are not yet `Sendable` in v1.0 — see argmax's 1.0 release notes. Our `actor Transcriber` is the isolation boundary; we never pass `WhisperKit` instances across actors.
- Cold start: `Transcriber.init` is `async` and takes ~1–3 s (model load + Metal/ANE warmup). The app shows a "Loading model…" menu bar state during this period.

## 7. Build, signing, and distribution

- Configure the Xcode target's signing to **"Sign to Run Locally"** — this is Xcode's standard ad-hoc path, which signs nested content correctly at build time.
- `scripts/build_app.sh`:
  ```bash
  xcodebuild -project Mumblur.xcodeproj \
             -scheme Mumblur \
             -configuration Release \
             -derivedDataPath build/
  # Xcode has already signed nested frameworks (WhisperKit etc.) and the app
  # bundle ad-hoc as part of the build. No --deep, no manual re-signing.
  rsync -a build/Build/Products/Release/Mumblur.app /Applications/
  ```
- **Avoid `codesign --force --deep`** — Apple discourages it; it recursively re-signs nested code and can mask errors. Xcode's build-time signing is the happy path.
- Hardened Runtime is enabled with `com.apple.security.device.audio-input` entitlement (for mic). Other entitlements stay off in v1 — no network sandbox (model download is over plain URLSession to argmax's HuggingFace).
- Install: copy `Mumblur.app` to `/Applications/`.
- No notarization. No Developer ID. v1 is single-user-on-dev-machine.

## 8. Verification harness

`scripts/verify_task.sh` adapted for the Swift toolchain. Each task ends with `scripts/verify_task.sh N`. The harness checks (per task):

- File-existence (xcodeproj parts, source files, Info.plist keys present).
- `cd MumblurCore && swift build` — confirms the core package compiles.
- `cd MumblurCore && swift test --skip Slow` — fast unit tests (slow integration test tagged via `XCTSkipIf(ProcessInfo.processInfo.environment["MUMBLUR_RUN_SLOW"] == nil)` or via a separate scheme; exact mechanism picked at plan stage).
- `xcodebuild build -project Mumblur.xcodeproj -scheme Mumblur -destination 'platform=macOS' -quiet` — confirms the app target compiles.
- For the final task: `codesign -dv build/.../Mumblur.app | grep Identifier` confirms the bundle has a stable identity.

A fresh subagent picking up Task N runs `scripts/verify_task.sh N-1` first to confirm the world matches what Task N expects. Same pattern as Python.

## 9. Testing strategy

XCTest target inside `MumblurCore` (not the app target):

- **`AudioRecorderTests`** — inject a fake `AVAudioFormat` + synthesized buffers; verify resampling output, accumulation order, and that `stop()` returns the concatenated samples in float32. Test the unplug path (stop throws → empty array, state reset).
- **`PasterTests`** — `paste("hello")` then read back via `NSPasteboard.general.string(forType: .string)`. The ⌘V keystroke assertion is omitted (no active app in tests); a comment documents the gap.
- **`TranscriberTests`** — unit tests with a fake `WhisperKitProtocol` (we wrap WhisperKit in our own protocol so it can be faked); a `Slow`-tagged integration test loads the real model and transcribes `hello_world.wav`. Slow tests excluded by default.
- **`HotkeyTests`** — exercise `HotkeyDispatcher` only: target-key vs other-key, isDown transitions, no-op on duplicate state. The actual `CGEventTap` install path is exercised only by Task 8's manual smoke test.
- **`RunnerTests`** — inject all dependencies as fakes; verify state transitions (idle → recording → stopping → transcribing → idle), single-flight rejection (deferred-Task pattern mirroring the Python deferred-worker test), min-hold discard, exception handling in the worker, shutdown idempotency, **and the TOCTOU regression test**: simulate `onRelease` racing with `onPress` (call them interleaved in a way that the lock should serialize), assert the second press is rejected.

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

- **Swift 6 strict concurrency on** for the package and app targets.
- **`@MainActor`**: `AppCoordinator`, all SwiftUI views, `applyState`, `showPermissionWarning`.
- **`actor`**: `Transcriber` — only this type owns the WhisperKit instance.
- **`OSAllocatedUnfairLock<MutableState>`** (from `os`, Swift-safe): used inside `Runner` to guard the small mutable struct (`state`, `pressTime`). Why not an actor: actors serialize via async hops, which would force `onPress`/`onRelease` to become `async` and complicate the event-tap callback chain (which is a synchronous C callback). The lock is held for nanoseconds; this is the canonical Apple-blessed Swift-safe path for tiny shared state. Raw `os_unfair_lock` is *not* used (Apple explicitly warns against using it from Swift).
- **`@Sendable`** annotations on all callback closures crossing concurrency domains.
- **`Task.detached(priority: .userInitiated)`** for the transcription worker — does *not* inherit any actor context; we don't want it implicitly hopping back to the listener thread. The task **handle is stored** in `Runner.MutableState.worker` so `shutdown()` can `cancel()` it. The worker checks `Task.isCancelled` before pasting; cancelled workers still transition state back to `.idle` via `defer`.
- **`@unchecked Sendable`** is used (sparingly) on `AudioRecorder`, `Hotkey`, and `Runner` to declare the types safe to pass across isolation boundaries; each has an internal lock or actor boundary that justifies the claim. WhisperKit is *not* declared Sendable; it's only ever touched from inside `actor Transcriber`.

## 12. Open questions (deferred to plan, not blocking)

1. **Exact WhisperKit model identifier for large-v3-turbo.** Resolved at plan stage by calling `WhisperKit.fetchAvailableModels()` or by checking `argmaxinc/whisperkit-coreml`'s current model list. Tentative pin: `openai_whisper-large-v3-v20240930_turbo_632MB`.
2. **WhisperKit return shape.** `transcribe(audioArray:)` returns `[TranscriptionResult]` per most recent docs; confirm by reading `WhisperKit.swift` at the version we pin.
3. **Slow-test skip mechanism.** Environment variable, separate test plan, or scheme — picked at plan stage.
4. **Menu bar icon animation during transcribing.** Static SF Symbol vs SwiftUI `.symbolEffect(.variableColor.iterative)`. Plan picks one.
5. **App sandbox.** Off in v1 for simplicity. If we want sandboxing later, we'd add `com.apple.security.app-sandbox` and `com.apple.security.network.client` (for WhisperKit's model download).
6. **Input Monitoring API call shape.** Whether `IOHIDRequestAccess` and `IOHIDCheckAccess` need to be called directly via `IOKit`/`IOKit.hid.usage` imports, or whether there's a higher-level Swift wrapper. Plan stage verifies the exact import set.

## 13. Definition of Done

- `Mumblur.app` builds via `scripts/build_app.sh` and installs to `/Applications/`.
- First launch prompts for Microphone (sync, awaited), Accessibility (async), and Input Monitoring (async). After the user grants the missing permissions in System Settings, the mandatory 2 s re-check timer picks up the new state (`AXIsProcessTrusted` + `IOHIDCheckAccess`) and starts the event tap without requiring a relaunch.
- Holding Right Option for ≥ 200 ms while speaking, then releasing, pastes the transcript at the cursor in any focused app within roughly decode time (≤ 1 s for short utterances on M3 Max).
- Menu bar icon transitions visibly between idle / recording / transcribing / warning states.
- Pressing Right Option during `recording`, `stopping`, or `transcribing` is rejected; log shows the rejection; in-flight transcription completes and pastes.
- `swift test` (fast tests in `MumblurCore`) passes.
- `MUMBLUR_RUN_SLOW=1 swift test --filter TranscriberTests.testIntegration` (or equivalent) passes once on the dev machine — real-model integration test.
- `xcodebuild build -scheme Mumblur` succeeds with no warnings beyond unavoidable WhisperKit warnings.
- `scripts/verify_task.sh N` (for the final N) passes.
- Permission grant persists across reboot **for the installed `.app` bundle** (no claim about persistence across rebuilds — see §5.6).
- The Python implementation on `feat/mvp` is left intact as a reference; the Swift implementation lives on `feat/swift`.
