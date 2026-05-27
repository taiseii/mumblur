# Mumblur Swift Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `Mumblur.app` MVP from spec `docs/superpowers/specs/2026-05-27-mumblur-swift-design.md` — a SwiftUI menu-bar dictation app on macOS 14+ that records audio while Right Option is held, transcribes via WhisperKit, and pastes the result at the cursor.

**Architecture:** A thin SwiftUI app target (`Mumblur.app`, ad-hoc-signed `.app` bundle with `LSUIElement=true`) wired to a testable Swift Package (`MumblurCore`). The package contains AudioRecorder (AVAudioEngine), Paster (`@MainActor` NSPasteboard + CGEvent ⌘V), Transcriber (`actor` wrapping WhisperKit), Hotkey (CGEventTap on `.flagsChanged` + pure HotkeyDispatcher state machine), Runner (`OSAllocatedUnfairLock<MutableState>` state machine: `idle → recording → stopping → transcribing → idle`, single-flight via `Task.detached` with tracked handle), and PermissionGate (Accessibility + Input Monitoring + Microphone, with mandatory 2 s re-check timer).

**Tech Stack:** Swift 6, macOS 14+, Xcode 16+. WhisperKit 1.0+ from `argmaxinc/argmax-oss-swift`. `xcodegen` for declarative Xcode project generation. SwiftUI `MenuBarExtra`. XCTest.

---

## Verification Harness — read this before executing any task

Each task ends with `scripts/verify_task.sh N`. The harness encodes the per-task contract — which files must exist, which `swift build` / `swift test` / `xcodebuild` commands must succeed — and exits non-zero if any check fails. A subagent picking up Task N can run `scripts/verify_task.sh N-1` first to confirm prior state.

- **Each task's last step before commit is `scripts/verify_task.sh N`.** If it fails, fix the cause and re-run; do not commit a failing state.
- **Commits land only after the harness passes.** Commit count = task progress.
- **The harness is offline.** The slow WhisperKit integration test is exercised separately by the user.

The script is created in Task 0 and extended by each subsequent task.

---

## Pre-flight

- [ ] **Confirm working directory**

Run: `pwd`
Expected: `/Users/taiseiigresb/Documents/.projects/mumbler`

- [ ] **Confirm spec and prior plan exist**

Run: `ls docs/superpowers/specs/2026-05-27-mumblur-swift-design.md docs/superpowers/plans/2026-05-27-mumblur-swift.md`
Expected: both files listed.

- [ ] **Confirm we are on `feat/mvp`**

Run: `git branch --show-current`
Expected: `feat/mvp`. (The spec mentioned a separate `feat/swift` branch; this plan keeps everything on `feat/mvp` for simplicity. The Python implementation stays in `src/mumbler/` as a reference; the Swift implementation is added alongside.)

- [ ] **Confirm Xcode 16+**

Run: `xcodebuild -version`
Expected: `Xcode 16.x` or higher. If lower, install Xcode 16 from the App Store / developer.apple.com before proceeding.

- [ ] **Install xcodegen (one-time)**

Run: `which xcodegen || brew install xcodegen`
Expected: `xcodegen` resolves to a path. Used to generate `Mumblur.xcodeproj` declaratively from `project.yml`.

---

## Task 0: Verification harness skeleton

**Why first:** Every task ends with `scripts/verify_task.sh N`. We need the script (and its Task 0 branch) before any other task can complete.

**Files:**
- Create: `scripts/verify_task.sh`

- [ ] **Step 1: Create the harness script**

Run: `mkdir -p scripts`

Write `scripts/verify_task.sh` with EXACTLY this content:

```bash
#!/usr/bin/env bash
# Verification harness for mumblur. Run `scripts/verify_task.sh N` after Task N.
# Exits 0 with "Task N OK" on success; non-zero with a failure message otherwise.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <task-number>" >&2
    exit 2
fi

TASK="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }
need_file() { [[ -f "$1" ]] || fail "missing file: $1"; }
need_dir()  { [[ -d "$1" ]] || fail "missing dir: $1"; }
absent()    { [[ ! -e "$1" ]] || fail "should not exist: $1"; }

core_build()  { (cd MumblurCore && swift build) >/dev/null; }
core_test()   { (cd MumblurCore && swift test) >/dev/null; }
app_build()   { xcodebuild build -project Mumblur.xcodeproj -scheme Mumblur \
                  -destination 'platform=macOS' -quiet >/dev/null; }

case "$TASK" in
    0)
        need_file scripts/verify_task.sh
        [[ -x scripts/verify_task.sh ]] || fail "scripts/verify_task.sh is not executable"
        ;;
    1)
        need_file MumblurCore/Package.swift
        need_dir  MumblurCore/Sources/MumblurCore
        need_dir  MumblurCore/Tests/MumblurCoreTests
        need_file project.yml
        need_dir  Mumblur.xcodeproj
        need_dir  App
        need_file App/MumblurApp.swift
        need_file App/Resources/Info.plist
        core_build
        ;;
    2)
        bash "$0" 1
        need_file MumblurCore/Sources/MumblurCore/Logging.swift
        core_build
        ;;
    3)
        bash "$0" 2
        need_file MumblurCore/Sources/MumblurCore/PermissionGate.swift
        need_file MumblurCore/Tests/MumblurCoreTests/PermissionGateTests.swift
        core_test
        ;;
    4)
        bash "$0" 3
        need_file MumblurCore/Sources/MumblurCore/AudioRecorder.swift
        need_file MumblurCore/Tests/MumblurCoreTests/AudioRecorderTests.swift
        core_test
        ;;
    5)
        bash "$0" 4
        need_file MumblurCore/Sources/MumblurCore/Paster.swift
        need_file MumblurCore/Tests/MumblurCoreTests/PasterTests.swift
        core_test
        ;;
    6)
        bash "$0" 5
        need_file MumblurCore/Sources/MumblurCore/Hotkey.swift
        need_file MumblurCore/Tests/MumblurCoreTests/HotkeyTests.swift
        core_test
        ;;
    7)
        bash "$0" 6
        need_file MumblurCore/Sources/MumblurCore/Transcriber.swift
        need_file MumblurCore/Tests/MumblurCoreTests/TranscriberTests.swift
        core_test
        ;;
    8)
        bash "$0" 7
        need_file MumblurCore/Sources/MumblurCore/Runner.swift
        need_file MumblurCore/Tests/MumblurCoreTests/RunnerTests.swift
        core_test
        ;;
    9)
        bash "$0" 8
        need_file App/AppCoordinator.swift
        need_file App/MenuBarContent.swift
        app_build
        ;;
    10)
        bash "$0" 9
        need_file App/PermissionsCoordinator.swift
        app_build
        ;;
    11)
        bash "$0" 10
        need_file scripts/build_app.sh
        [[ -x scripts/build_app.sh ]] || fail "scripts/build_app.sh is not executable"
        need_file App/Resources/Mumblur.entitlements
        # Sanity-check Info.plist has the keys we need.
        grep -q 'LSUIElement' App/Resources/Info.plist || fail "Info.plist missing LSUIElement"
        grep -q 'NSMicrophoneUsageDescription' App/Resources/Info.plist \
            || fail "Info.plist missing NSMicrophoneUsageDescription"
        app_build
        ;;
    12)
        bash "$0" 11
        core_test
        app_build
        ;;
    *)
        fail "unknown task: $TASK"
        ;;
esac

echo "Task $TASK OK"
```

- [ ] **Step 2: Make executable and self-test**

Run:
```bash
chmod +x scripts/verify_task.sh
scripts/verify_task.sh 0
```
Expected: prints `Task 0 OK`, exit 0.

- [ ] **Step 3: Commit**

Run:
```bash
git add scripts/verify_task.sh
git commit -m "chore(harness): per-task verification script for Swift build"
```

---

## Task 1: Project scaffold — SPM core package + xcodegen app project

**Files:**
- Create: `MumblurCore/Package.swift`
- Create: `MumblurCore/Sources/MumblurCore/MumblurCore.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/MumblurCoreTests.swift`
- Create: `project.yml`
- Create: `App/MumblurApp.swift`
- Create: `App/Resources/Info.plist`
- Create: `App/Resources/Assets.xcassets/Contents.json`
- Create: `App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Generate: `Mumblur.xcodeproj/` (via `xcodegen`)

- [ ] **Step 1: Create the SPM core package**

Run:
```bash
mkdir -p MumblurCore/Sources/MumblurCore MumblurCore/Tests/MumblurCoreTests
```

Write `MumblurCore/Package.swift`:

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MumblurCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "MumblurCore", targets: ["MumblurCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MumblurCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .testTarget(
            name: "MumblurCoreTests",
            dependencies: ["MumblurCore"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
```

Write `MumblurCore/Sources/MumblurCore/MumblurCore.swift`:

```swift
import Foundation

public enum MumblurCore {
    public static let version = "0.1.0"
}
```

Write `MumblurCore/Tests/MumblurCoreTests/MumblurCoreTests.swift`:

```swift
import XCTest
@testable import MumblurCore

final class MumblurCoreTests: XCTestCase {
    func testVersionIsNonEmpty() {
        XCTAssertFalse(MumblurCore.version.isEmpty)
    }
}
```

Reuse the existing `tests/fixtures/hello_world.wav` from the Python project for later WhisperKit integration tests:

```bash
mkdir -p MumblurCore/Tests/MumblurCoreTests/Fixtures
cp tests/fixtures/hello_world.wav MumblurCore/Tests/MumblurCoreTests/Fixtures/
```

- [ ] **Step 2: Build the core package**

Run: `(cd MumblurCore && swift build)`
Expected: completes successfully. First build resolves `argmax-oss-swift`; this may take a few minutes.

- [ ] **Step 3: Run the placeholder core test**

Run: `(cd MumblurCore && swift test)`
Expected: 1 test passes.

- [ ] **Step 4: Create the app target sources**

Run: `mkdir -p App/Resources/Assets.xcassets/AppIcon.appiconset`

Write `App/MumblurApp.swift`:

```swift
import SwiftUI

@main
struct MumblurApp: App {
    var body: some Scene {
        MenuBarExtra("Mumblur", systemImage: "mic") {
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
```

Write `App/Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>world.questable.mumblur</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Mumblur</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Mumblur records your voice locally and transcribes it to text. Audio never leaves your Mac.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026. All rights reserved.</string>
</dict>
</plist>
```

Write `App/Resources/Assets.xcassets/Contents.json`:

```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

Write `App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`:

```json
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

- [ ] **Step 5: Create the xcodegen project.yml**

Write `project.yml`:

```yaml
name: Mumblur
options:
  bundleIdPrefix: world.questable
  deploymentTarget:
    macOS: "14.0"
  developmentLanguage: en
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "6.0"
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    DEAD_CODE_STRIPPING: YES
packages:
  MumblurCore:
    path: MumblurCore
targets:
  Mumblur:
    type: application
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: App
        excludes:
          - Resources/Info.plist
          - Resources/Mumblur.entitlements
    resources:
      - path: App/Resources/Assets.xcassets
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: world.questable.mumblur
        PRODUCT_NAME: Mumblur
        INFOPLIST_FILE: App/Resources/Info.plist
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "-"
        ENABLE_HARDENED_RUNTIME: YES
        SWIFT_STRICT_CONCURRENCY: complete
        LD_RUNPATH_SEARCH_PATHS:
          - "@executable_path/../Frameworks"
    dependencies:
      - package: MumblurCore
        product: MumblurCore
```

- [ ] **Step 6: Generate the Xcode project**

Run: `xcodegen generate`
Expected: prints `Loaded project: ...` and creates `Mumblur.xcodeproj/`.

- [ ] **Step 7: Build the app target**

Run: `xcodebuild build -project Mumblur.xcodeproj -scheme Mumblur -destination 'platform=macOS' -quiet`
Expected: builds successfully. First build downloads WhisperKit transitively (this may take several minutes).

- [ ] **Step 8: Update .gitignore**

Append (do not replace) these lines to `.gitignore`:

```
# Swift / Xcode build artifacts
.build/
build/
DerivedData/
Mumblur.xcodeproj/xcuserdata/
Mumblur.xcodeproj/project.xcworkspace/xcuserdata/
*.xcuserstate
```

- [ ] **Step 9: Run harness**

Run: `scripts/verify_task.sh 1`
Expected: `Task 1 OK`.

- [ ] **Step 10: Commit**

Run:
```bash
git add MumblurCore/ project.yml App/ Mumblur.xcodeproj/ .gitignore
git commit -m "chore(swift): scaffold MumblurCore SPM package + xcodegen project"
```

---

## Task 2: `Logging.swift` — shared os.Logger instances

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/Logging.swift`

- [ ] **Step 1: Implement**

Write `MumblurCore/Sources/MumblurCore/Logging.swift`:

```swift
import Foundation
import os

extension Logger {
    public static let app        = Logger(subsystem: "world.questable.mumblur", category: "app")
    public static let hotkey     = Logger(subsystem: "world.questable.mumblur", category: "hotkey")
    public static let audio      = Logger(subsystem: "world.questable.mumblur", category: "audio")
    public static let transcribe = Logger(subsystem: "world.questable.mumblur", category: "transcribe")
    public static let paste      = Logger(subsystem: "world.questable.mumblur", category: "paste")
    public static let runner     = Logger(subsystem: "world.questable.mumblur", category: "runner")
    public static let perms      = Logger(subsystem: "world.questable.mumblur", category: "perms")
}
```

- [ ] **Step 2: Build to confirm the file compiles**

Run: `(cd MumblurCore && swift build)`
Expected: completes successfully.

- [ ] **Step 3: Run harness**

Run: `scripts/verify_task.sh 2`
Expected: `Task 2 OK`.

- [ ] **Step 4: Commit**

Run:
```bash
git add MumblurCore/Sources/MumblurCore/Logging.swift
git commit -m "feat(core): shared os.Logger instances per subsystem"
```

---

## Task 3: `PermissionGate.swift` — Accessibility, Input Monitoring, Microphone

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/PermissionGate.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/PermissionGateTests.swift`

PermissionGate is mostly OS-API thin wrappers; tests verify the enum semantics + that the calls don't crash.

- [ ] **Step 1: Write the failing test**

Write `MumblurCore/Tests/MumblurCoreTests/PermissionGateTests.swift`:

```swift
import XCTest
@testable import MumblurCore

final class PermissionGateTests: XCTestCase {
    func testEnsureAccessibility_returnsAValidResult() {
        // We can't deterministically grant/deny in a test, but we can confirm the
        // call returns one of the documented states without throwing or hanging.
        let result = PermissionGate.ensureAccessibility(prompt: false)
        XCTAssertTrue([.granted, .denied, .prompted].contains(result))
    }

    func testEnsureInputMonitoring_returnsAValidResult() {
        let result = PermissionGate.ensureInputMonitoring(prompt: false)
        XCTAssertTrue([.granted, .denied, .prompted].contains(result))
    }

    func testEnsureMicrophone_returnsAValidResult() async {
        let result = await PermissionGate.ensureMicrophone()
        XCTAssertTrue([.granted, .denied, .prompted].contains(result))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `(cd MumblurCore && swift test --filter PermissionGateTests)`
Expected: FAIL — `cannot find 'PermissionGate' in scope`.

- [ ] **Step 3: Implement**

Write `MumblurCore/Sources/MumblurCore/PermissionGate.swift`:

```swift
import Foundation
import AVFoundation
import ApplicationServices
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `(cd MumblurCore && swift test --filter PermissionGateTests)`
Expected: 3 tests PASS.

- [ ] **Step 5: Run harness**

Run: `scripts/verify_task.sh 3`
Expected: `Task 3 OK`.

- [ ] **Step 6: Commit**

Run:
```bash
git add MumblurCore/Sources/MumblurCore/PermissionGate.swift \
        MumblurCore/Tests/MumblurCoreTests/PermissionGateTests.swift
git commit -m "feat(core): PermissionGate for Accessibility / Input Monitoring / Microphone"
```

---

## Task 4: `AudioRecorder.swift` — AVAudioEngine wrapper

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/AudioRecorder.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/AudioRecorderTests.swift`

The recorder exposes a protocol so tests can inject a fake without an AVAudioEngine. The concrete implementation uses AVAudioEngine but it's not exercised in unit tests (no available mic in CI/test environments).

- [ ] **Step 1: Write the failing test**

Write `MumblurCore/Tests/MumblurCoreTests/AudioRecorderTests.swift`:

```swift
import XCTest
@testable import MumblurCore

final class AudioRecorderTests: XCTestCase {
    func testFakeRecorder_startThenStopReturnsBuffered() throws {
        let rec = FakeAudioRecorder()
        try rec.start()
        rec.push([0.1, 0.2, 0.3])
        rec.push([0.4, 0.5])
        let samples = rec.stop()
        XCTAssertEqual(samples, [0.1, 0.2, 0.3, 0.4, 0.5])
    }

    func testFakeRecorder_stopWithoutStartReturnsEmpty() {
        let rec = FakeAudioRecorder()
        let samples = rec.stop()
        XCTAssertEqual(samples, [])
    }

    func testFakeRecorder_secondCycleResetsBuffer() throws {
        let rec = FakeAudioRecorder()
        try rec.start()
        rec.push([1.0, 2.0])
        _ = rec.stop()
        try rec.start()
        rec.push([9.0])
        let samples = rec.stop()
        XCTAssertEqual(samples, [9.0])
    }

    func testFakeRecorder_abortIfActiveResetsState() throws {
        let rec = FakeAudioRecorder()
        try rec.start()
        rec.push([1.0])
        rec.abortIfActive()
        // After abort, a new cycle starts clean.
        try rec.start()
        let samples = rec.stop()
        XCTAssertEqual(samples, [])
    }

    func testFakeRecorder_startTwiceThrows() throws {
        let rec = FakeAudioRecorder()
        try rec.start()
        XCTAssertThrowsError(try rec.start())
    }

    func testFakeRecorder_stopErrorReturnsEmpty() throws {
        let rec = FakeAudioRecorder()
        try rec.start()
        rec.push([0.1])
        rec.simulateStopError = true
        XCTAssertEqual(rec.stop(), [])
        // And a fresh cycle works.
        try rec.start()
        XCTAssertEqual(rec.stop(), [])
    }
}

/// Fake recorder used in Runner tests too. Exposed `@testable` from MumblurCore.
final class FakeAudioRecorder: AudioRecording, @unchecked Sendable {
    private var chunks: [[Float]] = []
    private var active: Bool = false
    var simulateStopError: Bool = false

    func start() throws {
        if active { throw NSError(domain: "FakeAudioRecorder", code: 1) }
        chunks = []
        active = true
    }

    func push(_ samples: [Float]) {
        guard active else { return }
        chunks.append(samples)
    }

    func stop() -> [Float] {
        guard active else { return [] }
        active = false
        if simulateStopError {
            chunks = []
            return []
        }
        let flat = chunks.flatMap { $0 }
        chunks = []
        return flat
    }

    func abortIfActive() {
        active = false
        chunks = []
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `(cd MumblurCore && swift test --filter AudioRecorderTests)`
Expected: FAIL — `cannot find 'AudioRecording' in scope`.

- [ ] **Step 3: Implement**

Write `MumblurCore/Sources/MumblurCore/AudioRecorder.swift`:

```swift
import Foundation
import AVFoundation
import os

public protocol AudioRecording: AnyObject, Sendable {
    func start() throws
    func stop() -> [Float]
    func abortIfActive()
}

public final class AudioRecorder: AudioRecording, @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var chunks: [[Float]] = []
    private var converter: AVAudioConverter?
    private var active: Bool = false

    public init() throws {
        // Engine is lazily configured on start(); init only verifies we can ask
        // the input node for a format (which can throw on devices with no mic).
        _ = engine.inputNode.outputFormat(forBus: 0)
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if active {
            throw NSError(
                domain: "MumblurCore.AudioRecorder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "already recording"]
            )
        }
        chunks = []

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "MumblurCore.AudioRecorder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "cannot build target format"]
            )
        }

        // If the input is already 16 kHz mono float32, the converter is a no-op
        // identity. Otherwise it downsamples / mixes channels.
        if inputFormat.sampleRate != targetFormat.sampleRate
            || inputFormat.channelCount != targetFormat.channelCount {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            converter = nil
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.onAudio(buffer: buffer, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
        active = true
        Logger.audio.debug("recording started")
    }

    public func stop() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return [] }
        active = false
        do {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        } catch {
            Logger.audio.error("engine stop error: \(error.localizedDescription)")
            chunks = []
            return []
        }
        let out = chunks.flatMap { $0 }
        chunks = []
        Logger.audio.debug("recording stopped: \(out.count) samples")
        return out
    }

    public func abortIfActive() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        active = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        chunks = []
    }

    private func onAudio(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        let outBuffer: AVAudioPCMBuffer
        if let converter {
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate
                    / buffer.format.sampleRate
                + 1024
            )
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity)
            else { return }
            var err: NSError?
            let status = converter.convert(to: out, error: &err) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .error || err != nil { return }
            outBuffer = out
        } else {
            outBuffer = buffer
        }
        guard let floatChannelData = outBuffer.floatChannelData else { return }
        let frames = Int(outBuffer.frameLength)
        let monoPtr = floatChannelData[0]
        let samples = Array(UnsafeBufferPointer(start: monoPtr, count: frames))
        lock.lock()
        if active { chunks.append(samples) }
        lock.unlock()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `(cd MumblurCore && swift test --filter AudioRecorderTests)`
Expected: 6 tests PASS.

- [ ] **Step 5: Run harness**

Run: `scripts/verify_task.sh 4`
Expected: `Task 4 OK`.

- [ ] **Step 6: Commit**

Run:
```bash
git add MumblurCore/Sources/MumblurCore/AudioRecorder.swift \
        MumblurCore/Tests/MumblurCoreTests/AudioRecorderTests.swift
git commit -m "feat(core): AudioRecorder with AVAudioEngine + FakeAudioRecorder"
```

---

## Task 5: `Paster.swift` — @MainActor NSPasteboard + CGEvent ⌘V

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/Paster.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/PasterTests.swift`

- [ ] **Step 1: Write the failing test**

Write `MumblurCore/Tests/MumblurCoreTests/PasterTests.swift`:

```swift
import XCTest
import AppKit
@testable import MumblurCore

@MainActor
final class PasterTests: XCTestCase {
    func testPaste_writesToPasteboardAndCallsKeystroke() async {
        let pb = NSPasteboard.general
        pb.clearContents()
        let spy = KeystrokeSpy()
        let paster = Paster(keystroke: spy)

        await paster.paste("hello mumblur")

        XCTAssertEqual(pb.string(forType: .string), "hello mumblur")
        XCTAssertEqual(spy.calls, ["cmd+v"])
    }

    func testPaste_emptyStringIsNoop() async {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("sentinel", forType: .string)
        let spy = KeystrokeSpy()
        let paster = Paster(keystroke: spy)

        await paster.paste("")

        XCTAssertEqual(pb.string(forType: .string), "sentinel")
        XCTAssertEqual(spy.calls, [])
    }

    func testPaste_whitespaceOnlyIsNoop() async {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("sentinel2", forType: .string)
        let spy = KeystrokeSpy()
        let paster = Paster(keystroke: spy)

        await paster.paste("   \n\t  ")

        XCTAssertEqual(pb.string(forType: .string), "sentinel2")
        XCTAssertEqual(spy.calls, [])
    }
}

/// Test helper. Records cmd+v calls instead of synthesizing real events.
final class KeystrokeSpy: KeystrokeSending, @unchecked Sendable {
    var calls: [String] = []
    func sendCmdV() {
        calls.append("cmd+v")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `(cd MumblurCore && swift test --filter PasterTests)`
Expected: FAIL — `cannot find 'Paster' in scope`.

- [ ] **Step 3: Implement**

Write `MumblurCore/Sources/MumblurCore/Paster.swift`:

```swift
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

    public init(keystroke: KeystrokeSending = DefaultKeystrokeSender()) {
        self.keystroke = keystroke
    }

    public func paste(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        keystroke.sendCmdV()
        Logger.paste.debug("pasted \(text.count) chars")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `(cd MumblurCore && swift test --filter PasterTests)`
Expected: 3 tests PASS.

Note: These tests mutate the system pasteboard. The `KeystrokeSpy` prevents real ⌘V from firing into the test runner.

- [ ] **Step 5: Run harness**

Run: `scripts/verify_task.sh 5`
Expected: `Task 5 OK`.

- [ ] **Step 6: Commit**

Run:
```bash
git add MumblurCore/Sources/MumblurCore/Paster.swift \
        MumblurCore/Tests/MumblurCoreTests/PasterTests.swift
git commit -m "feat(core): Paster on @MainActor with injectable keystroke sender"
```

---

## Task 6: `Hotkey.swift` — CGEventTap + pure HotkeyDispatcher

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/Hotkey.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/HotkeyTests.swift`

The pure `HotkeyDispatcher` state machine is unit-tested; the `Hotkey` class wrapping `CGEventTap` is exercised only by manual smoke (Task 12).

- [ ] **Step 1: Write the failing test**

Write `MumblurCore/Tests/MumblurCoreTests/HotkeyTests.swift`:

```swift
import XCTest
@testable import MumblurCore

final class HotkeyTests: XCTestCase {
    private let rightOption: CGKeyCode = 0x3D
    private let leftOption: CGKeyCode = 0x3A

    func testTargetKeycode_pressThenReleaseEmitsBoth() {
        var events: [String] = []
        var d = HotkeyDispatcher(
            targetKeycode: rightOption,
            onPress: { events.append("press") },
            onRelease: { events.append("release") }
        )
        d.handle(keycode: rightOption)
        d.handle(keycode: rightOption)
        XCTAssertEqual(events, ["press", "release"])
    }

    func testNonTargetKeycode_ignored() {
        var events: [String] = []
        var d = HotkeyDispatcher(
            targetKeycode: rightOption,
            onPress: { events.append("press") },
            onRelease: { events.append("release") }
        )
        d.handle(keycode: leftOption)
        d.handle(keycode: leftOption)
        XCTAssertEqual(events, [])
    }

    func testInterleavedRightAndLeftOption_tracksRightCorrectly() {
        // User scenario: holds Left Option, then taps Right Option once.
        // Aggregate .maskAlternate would be misleading; per-keycode toggle is correct.
        var events: [String] = []
        var d = HotkeyDispatcher(
            targetKeycode: rightOption,
            onPress: { events.append("press") },
            onRelease: { events.append("release") }
        )
        d.handle(keycode: leftOption)   // ignored
        d.handle(keycode: rightOption)  // press
        d.handle(keycode: rightOption)  // release
        d.handle(keycode: leftOption)   // ignored
        XCTAssertEqual(events, ["press", "release"])
    }

    func testThreePressesEmitsPressReleasePress() {
        // A flagsChanged stream that produces three down-transitions for the target
        // results in press, release, press (toggle semantics).
        var events: [String] = []
        var d = HotkeyDispatcher(
            targetKeycode: rightOption,
            onPress: { events.append("press") },
            onRelease: { events.append("release") }
        )
        d.handle(keycode: rightOption)
        d.handle(keycode: rightOption)
        d.handle(keycode: rightOption)
        XCTAssertEqual(events, ["press", "release", "press"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `(cd MumblurCore && swift test --filter HotkeyTests)`
Expected: FAIL — `cannot find 'HotkeyDispatcher' in scope`.

- [ ] **Step 3: Implement**

Write `MumblurCore/Sources/MumblurCore/Hotkey.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `(cd MumblurCore && swift test --filter HotkeyTests)`
Expected: 4 tests PASS.

- [ ] **Step 5: Run harness**

Run: `scripts/verify_task.sh 6`
Expected: `Task 6 OK`.

- [ ] **Step 6: Commit**

Run:
```bash
git add MumblurCore/Sources/MumblurCore/Hotkey.swift \
        MumblurCore/Tests/MumblurCoreTests/HotkeyTests.swift
git commit -m "feat(core): HotkeyDispatcher (pure) + Hotkey CGEventTap wrapper"
```

---

## Task 7: `Transcriber.swift` — actor wrapping WhisperKit

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/Transcriber.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/TranscriberTests.swift`

The fast tests use an injectable fake conforming to `WhisperKitTranscribing`. A slow integration test loads the real model — gated by `MUMBLUR_RUN_SLOW=1`.

- [ ] **Step 1: Write the failing test**

Write `MumblurCore/Tests/MumblurCoreTests/TranscriberTests.swift`:

```swift
import XCTest
@testable import MumblurCore

final class TranscriberTests: XCTestCase {
    func testTranscribe_joinsSegmentsAndTrims() async throws {
        let fake = FakeWhisperKit()
        fake.nextSegments = [
            FakeWhisperKit.Segment(text: "  hello "),
            FakeWhisperKit.Segment(text: "world  "),
        ]
        let t = Transcriber(kit: fake, language: nil)
        let result = try await t.transcribe([0.0, 0.1, 0.2])
        XCTAssertEqual(result, "hello world")
        XCTAssertEqual(fake.transcribeCalls.count, 1)
    }

    func testTranscribe_emptySamplesReturnsEmpty() async throws {
        let fake = FakeWhisperKit()
        let t = Transcriber(kit: fake, language: nil)
        let result = try await t.transcribe([])
        XCTAssertEqual(result, "")
        XCTAssertEqual(fake.transcribeCalls.count, 0)
    }

    func testTranscribe_languageNilEnablesDetectLanguage() async throws {
        let fake = FakeWhisperKit()
        let t = Transcriber(kit: fake, language: nil)
        _ = try await t.transcribe([0.1])
        XCTAssertEqual(fake.lastLanguage, nil)
        XCTAssertEqual(fake.lastDetectLanguage, true)
    }

    func testTranscribe_languageSetDisablesAutoDetect() async throws {
        let fake = FakeWhisperKit()
        let t = Transcriber(kit: fake, language: "en")
        _ = try await t.transcribe([0.1])
        XCTAssertEqual(fake.lastLanguage, "en")
        XCTAssertEqual(fake.lastDetectLanguage, false)
    }

    /// Slow: loads the real WhisperKit model. Skipped unless MUMBLUR_RUN_SLOW=1.
    func testIntegration_transcribesHelloWorldFixture() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MUMBLUR_RUN_SLOW"] == "1",
            "Slow integration test (set MUMBLUR_RUN_SLOW=1 to enable)"
        )
        let url = Bundle.module.url(forResource: "hello_world", withExtension: "wav",
                                    subdirectory: "Fixtures")
        guard let url else {
            XCTFail("missing hello_world.wav fixture")
            return
        }
        let samples = try loadWavFloatMono16kHz(url: url)
        let kit = try await RealWhisperKit.make()
        let t = Transcriber(kit: kit, language: nil)
        let result = try await t.transcribe(samples).lowercased()
        XCTAssertTrue(result.contains("hello") && result.contains("world"),
                      "got: \(result)")
    }
}

/// Helper exposed for tests. Loads a 16 kHz mono PCM WAV into [Float].
func loadWavFloatMono16kHz(url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    // WAV header is 44 bytes; data is signed 16-bit LE PCM mono after that.
    guard data.count > 44 else { return [] }
    let pcm = data.subdata(in: 44..<data.count)
    var out = [Float](repeating: 0, count: pcm.count / 2)
    pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let ptr = raw.bindMemory(to: Int16.self)
        for i in 0..<out.count {
            out[i] = Float(ptr[i]) / 32768.0
        }
    }
    return out
}

/// Fake conforming to WhisperKitTranscribing.
final class FakeWhisperKit: WhisperKitTranscribing, @unchecked Sendable {
    struct Segment: WhisperKitSegment { var text: String }

    var nextSegments: [Segment] = []
    var transcribeCalls: [[Float]] = []
    var lastLanguage: String? = nil
    var lastDetectLanguage: Bool? = nil

    func transcribe(audioArray: [Float],
                    language: String?,
                    detectLanguage: Bool) async throws -> [any WhisperKitSegment] {
        transcribeCalls.append(audioArray)
        lastLanguage = language
        lastDetectLanguage = detectLanguage
        return nextSegments
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `(cd MumblurCore && swift test --filter TranscriberTests)`
Expected: FAIL — `cannot find 'Transcriber' in scope`.

- [ ] **Step 3: Implement**

Write `MumblurCore/Sources/MumblurCore/Transcriber.swift`:

```swift
import Foundation
import WhisperKit
import os

public protocol WhisperKitSegment: Sendable {
    var text: String { get }
}

/// Thin abstraction over WhisperKit so it can be faked. The real implementation
/// lives in `RealWhisperKit` below.
public protocol WhisperKitTranscribing: Sendable {
    func transcribe(audioArray: [Float],
                    language: String?,
                    detectLanguage: Bool) async throws -> [any WhisperKitSegment]
}

public protocol Transcribing: Sendable {
    func transcribe(_ samples: [Float]) async throws -> String
}

public actor Transcriber: Transcribing {
    private let kit: any WhisperKitTranscribing
    private let language: String?

    public init(kit: any WhisperKitTranscribing, language: String?) {
        self.kit = kit
        self.language = language
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { return "" }
        let detect = (language == nil)
        let segments = try await kit.transcribe(
            audioArray: samples,
            language: language,
            detectLanguage: detect
        )
        let joined = segments.map(\.text).joined()
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Concrete WhisperKit-backed implementation. Constructed via async factory.
public final class RealWhisperKit: WhisperKitTranscribing, @unchecked Sendable {
    private let pipeline: WhisperKit

    private init(pipeline: WhisperKit) {
        self.pipeline = pipeline
    }

    public static func make(modelHint: String? = nil) async throws -> RealWhisperKit {
        let resolved = try await resolveModelName(preferred: modelHint)
        Logger.transcribe.info("loading WhisperKit model: \(resolved, privacy: .public)")
        let pipeline = try await WhisperKit(WhisperKitConfig(model: resolved))
        return RealWhisperKit(pipeline: pipeline)
    }

    private static func resolveModelName(preferred: String?) async throws -> String {
        let available = try await WhisperKit.fetchAvailableModels()
        if let preferred, available.contains(preferred) { return preferred }
        // Prefer a turbo variant by name substring; fall back to the largest large-v3.
        if let turbo = available.first(where: { $0.lowercased().contains("turbo") }) {
            return turbo
        }
        if let largeV3 = available.first(where: { $0.lowercased().contains("large-v3") }) {
            Logger.transcribe.warning("no turbo variant found; falling back to \(largeV3, privacy: .public)")
            return largeV3
        }
        throw NSError(
            domain: "MumblurCore.Transcriber",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no suitable WhisperKit model found"]
        )
    }

    public func transcribe(audioArray: [Float],
                           language: String?,
                           detectLanguage: Bool) async throws -> [any WhisperKitSegment] {
        let options = DecodingOptions(
            language: language,
            detectLanguage: detectLanguage,
            usePrefillPrompt: true
        )
        let results = try await pipeline.transcribe(audioArray: audioArray,
                                                    decodeOptions: options)
        // `results` is [TranscriptionResult]; flatten its segments. The exact return
        // shape is verified against the pinned WhisperKit version; if the type name
        // is different in your version, update the cast accordingly.
        return results.flatMap { result in
            result.segments.map { Segment(text: $0.text) }
        }
    }

    private struct Segment: WhisperKitSegment {
        let text: String
    }
}
```

- [ ] **Step 4: Run fast tests to verify they pass**

Run: `(cd MumblurCore && swift test --filter TranscriberTests)`
Expected: 4 fast tests PASS; the slow integration test is skipped.

- [ ] **Step 5: Run harness**

Run: `scripts/verify_task.sh 7`
Expected: `Task 7 OK`.

- [ ] **Step 6: Commit**

Run:
```bash
git add MumblurCore/Sources/MumblurCore/Transcriber.swift \
        MumblurCore/Tests/MumblurCoreTests/TranscriberTests.swift
git commit -m "feat(core): Transcriber actor wrapping WhisperKit via WhisperKitTranscribing"
```

---

## Task 8: `Runner.swift` — locked state machine with worker Task tracking

**Files:**
- Create: `MumblurCore/Sources/MumblurCore/Runner.swift`
- Create: `MumblurCore/Tests/MumblurCoreTests/RunnerTests.swift`

This is the most subtle module. Tests verify:
- Happy path (press → release → paste).
- Short press discarded.
- Empty transcript not pasted.
- Single-flight: press during `transcribing` is rejected.
- TOCTOU window between `stop` and `transcribing` is closed.
- Transcribe / paste exceptions don't kill the loop.
- Shutdown aborts an active recording and cancels a worker.

- [ ] **Step 1: Write the failing test**

Write `MumblurCore/Tests/MumblurCoreTests/RunnerTests.swift`:

```swift
import XCTest
@testable import MumblurCore

final class RunnerTests: XCTestCase {
    func testFullCycle_recordsTranscribesPastes() async throws {
        let rec = FakeAudioRecorder()
        let tr = FakeTranscriber(text: "hello world")
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            minHoldMs: 0,
            clock: { Date(timeIntervalSince1970: 0) }
        )

        runner.onPress()
        // Snapshot state before release.
        XCTAssertEqual(runner.state, .recording)
        runner.onRelease()
        await waitUntilIdle(runner)

        let pasted = await paster.getCalls()
        XCTAssertEqual(pasted, ["hello world"])
        XCTAssertEqual(runner.state, .idle)
    }

    func testShortPress_discardsAndDoesNotPaste() async {
        let rec = FakeAudioRecorder()
        let tr = FakeTranscriber(text: "x")
        let paster = SpyPaster()
        var t: TimeInterval = 0
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            minHoldMs: 200,
            clock: { Date(timeIntervalSince1970: t) }
        )

        runner.onPress()
        t = 0.05    // 50 ms — under threshold
        runner.onRelease()
        await waitUntilIdle(runner)

        XCTAssertEqual(await paster.getCalls(), [])
        XCTAssertEqual(runner.state, .idle)
    }

    func testEmptyTranscript_doesNotPaste() async throws {
        let rec = FakeAudioRecorder()
        let tr = FakeTranscriber(text: "   ")
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            minHoldMs: 0
        )

        runner.onPress()
        runner.onRelease()
        await waitUntilIdle(runner)

        XCTAssertEqual(await paster.getCalls(), [])
    }

    func testPressDuringTranscribing_isRejected() async throws {
        let rec = FakeAudioRecorder()
        let tr = BlockingTranscriber(text: "result")
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            minHoldMs: 0
        )

        runner.onPress()
        runner.onRelease()
        // Wait until the worker has actually entered transcribe and is blocked.
        try await waitForState(runner, .transcribing)

        runner.onPress()                    // must be rejected
        XCTAssertEqual(runner.state, .transcribing)
        XCTAssertEqual(rec.startCount, 1)   // not 2

        tr.unblock()                        // let the worker finish
        await waitUntilIdle(runner)
        XCTAssertEqual(await paster.getCalls(), ["result"])
    }

    func testPressDuringStopping_isRejected() async throws {
        // Window: between recorder.stop() returning and state.transcribing assignment.
        // We simulate by making the FakeAudioRecorder's stop block briefly while we
        // call onPress.
        let rec = SlowStopRecorder()
        let tr = FakeTranscriber(text: "ok")
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            minHoldMs: 0
        )

        runner.onPress()
        let releaseTask = Task.detached(priority: .userInitiated) {
            runner.onRelease()
        }
        try await waitForState(runner, .stopping)
        runner.onPress()                    // must be rejected
        XCTAssertEqual(runner.state, .stopping)
        XCTAssertEqual(rec.startCount, 1)

        rec.unblockStop()
        await releaseTask.value
        await waitUntilIdle(runner)
    }

    func testTranscribeException_caughtLoopContinues() async throws {
        let rec = FakeAudioRecorder()
        let tr = ThrowingTranscriber()
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            minHoldMs: 0
        )

        runner.onPress()
        runner.onRelease()
        await waitUntilIdle(runner)

        XCTAssertEqual(await paster.getCalls(), [])
        // Second cycle still works.
        let tr2 = FakeTranscriber(text: "second")
        let runner2 = Runner(
            recorder: rec,
            transcriber: tr2,
            paster: paster,
            minHoldMs: 0
        )
        runner2.onPress()
        runner2.onRelease()
        await waitUntilIdle(runner2)
        XCTAssertEqual(await paster.getCalls(), ["second"])
    }

    func testShutdown_abortsRecordingAndReturnsToIdle() async {
        let rec = FakeAudioRecorder()
        let tr = FakeTranscriber()
        let paster = SpyPaster()
        let runner = Runner(
            recorder: rec,
            transcriber: tr,
            paster: paster,
            minHoldMs: 0
        )

        runner.onPress()
        XCTAssertEqual(runner.state, .recording)
        runner.shutdown()
        XCTAssertEqual(runner.state, .idle)
        // After shutdown, abortIfActive was called.
        XCTAssertGreaterThanOrEqual(rec.abortCount, 1)
    }

    // MARK: - Helpers

    /// Polls until runner.state == .idle (worker has finished).
    private func waitUntilIdle(_ runner: Runner) async {
        for _ in 0..<200 {
            if runner.state == .idle { return }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
        }
        XCTFail("timed out waiting for runner to return to .idle")
    }

    private func waitForState(_ runner: Runner, _ target: Runner.State) async throws {
        for _ in 0..<200 {
            if runner.state == target { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw NSError(domain: "test", code: 0,
                      userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(target)"])
    }
}

// MARK: - Fakes used in RunnerTests (also used elsewhere)

final class FakeTranscriber: Transcribing, @unchecked Sendable {
    private let text: String
    private(set) var calls: [[Float]] = []
    private let lock = NSLock()

    init(text: String = "hello") { self.text = text }

    func transcribe(_ samples: [Float]) async throws -> String {
        lock.lock(); calls.append(samples); lock.unlock()
        return text
    }
}

/// Transcriber that blocks inside transcribe() until unblocked.
final class BlockingTranscriber: Transcribing, @unchecked Sendable {
    private let text: String
    private let unblockEvent = AsyncStream<Void>.makeStream()

    init(text: String) { self.text = text }

    func transcribe(_ samples: [Float]) async throws -> String {
        var it = unblockEvent.stream.makeAsyncIterator()
        _ = await it.next()
        return text
    }

    func unblock() {
        unblockEvent.continuation.yield(())
        unblockEvent.continuation.finish()
    }
}

final class ThrowingTranscriber: Transcribing, @unchecked Sendable {
    struct Boom: Error {}
    func transcribe(_ samples: [Float]) async throws -> String { throw Boom() }
}

actor SpyPaster: Pasting {
    var calls: [String] = []
    func paste(_ text: String) async {
        calls.append(text)
    }
    func getCalls() -> [String] { calls }
}

/// FakeAudioRecorder extension to also track start/abort counts.
extension FakeAudioRecorder {
    var startCount: Int {
        // Hack: re-trigger start tracking by inspecting state. The protocol doesn't
        // expose this directly; tests increment via a side channel below.
        return _startCount
    }
    var abortCount: Int { _abortCount }
    private static var startCountKey = "startCount"
    private static var abortCountKey = "abortCount"
    var _startCount: Int {
        get { (objc_getAssociatedObject(self, &Self.startCountKey) as? Int) ?? 0 }
        set { objc_setAssociatedObject(self, &Self.startCountKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
    var _abortCount: Int {
        get { (objc_getAssociatedObject(self, &Self.abortCountKey) as? Int) ?? 0 }
        set { objc_setAssociatedObject(self, &Self.abortCountKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}

/// SlowStopRecorder — `stop()` blocks until `unblockStop()` is called. Used to
/// simulate the TOCTOU window between recorder.stop returning and state transition.
final class SlowStopRecorder: AudioRecording, @unchecked Sendable {
    private let stopGate = DispatchSemaphore(value: 0)
    private var active = false
    var startCount: Int = 0

    func start() throws { active = true; startCount += 1 }
    func stop() -> [Float] {
        stopGate.wait()      // blocks until unblockStop
        active = false
        return [0.0]
    }
    func abortIfActive() { active = false }
    func unblockStop() { stopGate.signal() }
}
```

Note: the `FakeAudioRecorder` count-tracking via associated objects is awkward; an alternative is to extend the original Task 4 `FakeAudioRecorder` directly to count starts/aborts. Pick the simpler option during implementation — see Step 3 below.

- [ ] **Step 2: Run to verify it fails**

Run: `(cd MumblurCore && swift test --filter RunnerTests)`
Expected: FAIL — `cannot find 'Runner' in scope`.

- [ ] **Step 3: Implement Runner and update FakeAudioRecorder counters**

First, replace the `FakeAudioRecorder` in `MumblurCore/Tests/MumblurCoreTests/AudioRecorderTests.swift` to track counters directly (cleaner than associated objects). Update the class body to:

```swift
final class FakeAudioRecorder: AudioRecording, @unchecked Sendable {
    private var chunks: [[Float]] = []
    private var active: Bool = false
    var simulateStopError: Bool = false
    var startCount: Int = 0
    var stopCount: Int = 0
    var abortCount: Int = 0

    func start() throws {
        if active { throw NSError(domain: "FakeAudioRecorder", code: 1) }
        chunks = []
        active = true
        startCount += 1
    }

    func push(_ samples: [Float]) {
        guard active else { return }
        chunks.append(samples)
    }

    func stop() -> [Float] {
        stopCount += 1
        guard active else { return [] }
        active = false
        if simulateStopError {
            chunks = []
            return []
        }
        let flat = chunks.flatMap { $0 }
        chunks = []
        return flat
    }

    func abortIfActive() {
        active = false
        chunks = []
        abortCount += 1
    }
}
```

Then remove the associated-object extension from `RunnerTests.swift` (delete the `extension FakeAudioRecorder { ... }` block); `startCount` and `abortCount` are now direct stored properties.

Now write `MumblurCore/Sources/MumblurCore/Runner.swift`:

```swift
import Foundation
import os

public final class Runner: @unchecked Sendable {
    public enum State: String, Sendable {
        case idle
        case recording
        case stopping
        case transcribing
    }

    public init(
        recorder: AudioRecording,
        transcriber: Transcribing,
        paster: Pasting,
        minHoldMs: Int = 200,
        clock: @escaping @Sendable () -> Date = { Date() },
        onStateChange: @escaping @Sendable (State) -> Void = { _ in }
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.paster = paster
        self.minHoldMs = minHoldMs
        self.clock = clock
        self.onStateChange = onStateChange
        self.lock = OSAllocatedUnfairLock(initialState: MutableState())
    }

    public var state: State { lock.withLock { $0.state } }

    public func onPress() {
        let shouldStart: Bool = lock.withLock { s in
            guard s.state == .idle else {
                Logger.runner.info("press ignored (state=\(s.state.rawValue))")
                return false
            }
            s.state = .recording
            s.pressTime = clock()
            return true
        }
        guard shouldStart else { return }
        onStateChange(.recording)
        do {
            try recorder.start()
        } catch {
            Logger.runner.error("recorder.start failed: \(error.localizedDescription)")
            lock.withLock { $0.state = .idle }
            onStateChange(.idle)
        }
    }

    public func onRelease() {
        let snap: (pressTime: Date, ok: Bool) = lock.withLock { s in
            guard s.state == .recording else { return (Date.distantPast, false) }
            s.state = .stopping
            return (s.pressTime, true)
        }
        guard snap.ok else { return }
        onStateChange(.stopping)

        let samples = recorder.stop()
        let heldMs = Int(clock().timeIntervalSince(snap.pressTime) * 1000)
        if heldMs < minHoldMs {
            lock.withLock { $0.state = .idle }
            onStateChange(.idle)
            return
        }

        lock.withLock { $0.state = .transcribing }
        onStateChange(.transcribing)

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.doWork(samples: samples)
        }

        // If doWork already finished and reset state to .idle, do NOT overwrite
        // it — cancel the task as a no-op and leave state alone. Otherwise store
        // the handle so shutdown() can cancel it.
        let shouldCancel: Bool = lock.withLock { s in
            guard s.state == .transcribing else { return true }
            s.worker = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    public func shutdown() {
        let (priorWorker, _) = lock.withLock { s -> (Task<Void, Never>?, State) in
            let w = s.worker
            s.worker = nil
            let was = s.state
            s.state = .idle
            return (w, was)
        }
        priorWorker?.cancel()
        recorder.abortIfActive()
        onStateChange(.idle)
    }

    // MARK: - Private

    private struct MutableState {
        var state: State = .idle
        var pressTime: Date = .distantPast
        var worker: Task<Void, Never>? = nil
    }

    private let recorder: AudioRecording
    private let transcriber: Transcribing
    private let paster: Pasting
    private let minHoldMs: Int
    private let clock: @Sendable () -> Date
    private let onStateChange: @Sendable (State) -> Void
    private let lock: OSAllocatedUnfairLock<MutableState>

    private func doWork(samples: [Float]) async {
        defer {
            lock.withLock { s in
                s.state = .idle
                s.worker = nil
            }
            onStateChange(.idle)
        }
        do {
            let text = try await transcriber.transcribe(samples)
            guard !Task.isCancelled,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            await paster.paste(text)
        } catch is CancellationError {
            Logger.runner.debug("worker cancelled")
        } catch {
            Logger.transcribe.error("transcribe failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `(cd MumblurCore && swift test --filter RunnerTests)`
Expected: 7 tests PASS.

If any test is flaky due to the `waitUntilIdle` / `waitForState` polling loops timing out, increase the iteration count from 200 to 400 (still ≤ 2 s wall clock).

- [ ] **Step 5: Run the full fast suite**

Run: `(cd MumblurCore && swift test)`
Expected: every fast test passes (MumblurCore + AudioRecorder + Paster + Hotkey + PermissionGate + Transcriber + Runner).

- [ ] **Step 6: Run harness**

Run: `scripts/verify_task.sh 8`
Expected: `Task 8 OK`.

- [ ] **Step 7: Commit**

Run:
```bash
git add MumblurCore/Sources/MumblurCore/Runner.swift \
        MumblurCore/Tests/MumblurCoreTests/RunnerTests.swift \
        MumblurCore/Tests/MumblurCoreTests/AudioRecorderTests.swift
git commit -m "feat(core): Runner state machine with worker Task tracking + TOCTOU close"
```

---

## Task 9: App shell — `AppCoordinator`, `MenuBarContent`, wire MumblurCore

**Files:**
- Modify: `App/MumblurApp.swift`
- Create: `App/AppCoordinator.swift`
- Create: `App/MenuBarContent.swift`

- [ ] **Step 1: Write `AppCoordinator.swift`**

Write `App/AppCoordinator.swift`:

```swift
import SwiftUI
import MumblurCore
import os

@MainActor
final class AppCoordinator: ObservableObject {
    enum UIState: String {
        case loadingModel
        case idle
        case recording
        case transcribing
        case permissionNeeded
        case fatalError
    }

    @Published var uiState: UIState = .loadingModel
    @Published var permissionMessage: String?
    @Published var lastError: String?

    private var runner: Runner?
    private var hotkey: HotkeyListening?
    private var recorder: AudioRecording?
    private var transcriber: Transcribing?

    func bootstrap() async {
        await PermissionGate.ensureMicrophone()
        _ = PermissionGate.ensureAccessibility(prompt: true)
        _ = PermissionGate.ensureInputMonitoring(prompt: true)

        do {
            let kit = try await RealWhisperKit.make()
            let transcriber = Transcriber(kit: kit, language: nil)
            let recorder = try AudioRecorder()
            let paster = Paster()

            let runner = Runner(
                recorder: recorder,
                transcriber: transcriber,
                paster: paster,
                minHoldMs: 200,
                onStateChange: { [weak self] state in
                    Task { @MainActor in self?.applyRunnerState(state) }
                }
            )
            self.recorder = recorder
            self.transcriber = transcriber
            self.runner = runner
            self.uiState = .idle
        } catch {
            Logger.app.error("bootstrap failed: \(error.localizedDescription)")
            self.lastError = error.localizedDescription
            self.uiState = .fatalError
        }
    }

    func tryStartHotkey() {
        guard let runner else { return }
        let hk = Hotkey { event in
            switch event {
            case .press:   runner.onPress()
            case .release: runner.onRelease()
            }
        }
        do {
            try hk.start()
            self.hotkey = hk
            Logger.app.info("hotkey started")
        } catch {
            Logger.app.error("hotkey start failed: \(error.localizedDescription)")
            self.uiState = .permissionNeeded
            self.permissionMessage = "Grant Accessibility and Input Monitoring to Mumblur."
        }
    }

    func quit() {
        runner?.shutdown()
        hotkey?.stop()
        NSApplication.shared.terminate(nil)
    }

    var icon: String {
        switch uiState {
        case .loadingModel:     return "hourglass"
        case .idle:             return "mic"
        case .recording:        return "mic.fill"
        case .transcribing:     return "waveform"
        case .permissionNeeded: return "exclamationmark.triangle"
        case .fatalError:       return "exclamationmark.octagon"
        }
    }

    private func applyRunnerState(_ s: Runner.State) {
        switch s {
        case .idle:         uiState = .idle
        case .recording:    uiState = .recording
        case .stopping:     uiState = .transcribing      // collapse for UI
        case .transcribing: uiState = .transcribing
        }
    }
}
```

- [ ] **Step 2: Write `MenuBarContent.swift`**

Write `App/MenuBarContent.swift`:

```swift
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading) {
            switch coordinator.uiState {
            case .loadingModel:
                Label("Loading model…", systemImage: "hourglass")
            case .idle:
                Label("Hold Right Option to dictate", systemImage: "mic")
            case .recording:
                Label("Recording…", systemImage: "mic.fill").foregroundStyle(.red)
            case .transcribing:
                Label("Transcribing…", systemImage: "waveform")
            case .permissionNeeded:
                Label(coordinator.permissionMessage ?? "Grant permissions",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .fatalError:
                Label(coordinator.lastError ?? "Error",
                      systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.red)
            }
            Divider()
            Button("Quit Mumblur") { coordinator.quit() }
                .keyboardShortcut("q")
        }
    }
}
```

- [ ] **Step 3: Update `MumblurApp.swift`**

Replace `App/MumblurApp.swift` with:

```swift
import SwiftUI
import MumblurCore

@main
struct MumblurApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coordinator: coordinator)
                .task { await coordinator.bootstrap() }
        } label: {
            Image(systemName: coordinator.icon)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.menu)
    }
}
```

(`AppCoordinator.bootstrap()` calls `tryStartHotkey()` itself once permissions are granted; the `.task` modifier is the canonical SwiftUI hook for async work on view appearance and respects the `@StateObject`'s lifecycle.)

- [ ] **Step 4: Re-generate the Xcode project**

Run: `xcodegen generate`
Expected: project updated to include the new App files.

- [ ] **Step 5: Build the app**

Run: `xcodebuild build -project Mumblur.xcodeproj -scheme Mumblur -destination 'platform=macOS' -quiet`
Expected: builds successfully.

- [ ] **Step 6: Run harness**

Run: `scripts/verify_task.sh 9`
Expected: `Task 9 OK`.

- [ ] **Step 7: Commit**

Run:
```bash
git add App/
git commit -m "feat(app): AppCoordinator + MenuBarContent wire MumblurCore"
```

---

## Task 10: `PermissionsCoordinator` — mandatory 2 s re-check timer

**Files:**
- Create: `App/PermissionsCoordinator.swift`
- Modify: `App/AppCoordinator.swift` to use it

- [ ] **Step 1: Write `PermissionsCoordinator.swift`**

Write `App/PermissionsCoordinator.swift`:

```swift
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
```

- [ ] **Step 2: Update `AppCoordinator.swift` to use the permissions coordinator**

Replace the entire `App/AppCoordinator.swift` with:

```swift
import SwiftUI
import MumblurCore
import os

@MainActor
final class AppCoordinator: ObservableObject {
    enum UIState: String {
        case loadingModel
        case idle
        case recording
        case transcribing
        case permissionNeeded
        case fatalError
    }

    @Published var uiState: UIState = .loadingModel
    @Published var permissionMessage: String?
    @Published var lastError: String?

    private var runner: Runner?
    private var hotkey: HotkeyListening?
    private var recorder: AudioRecording?
    private var transcriber: Transcribing?
    private var perms: PermissionsCoordinator!

    init() {
        // Two-phase: build perms with a callback, then trigger bootstrap.
        self.perms = PermissionsCoordinator { [weak self] snap in
            self?.applyPermissionSnapshot(snap)
        }
    }

    func bootstrap() async {
        await perms.bootstrap()
        do {
            let kit = try await RealWhisperKit.make()
            let transcriber = Transcriber(kit: kit, language: nil)
            let recorder = try AudioRecorder()
            let paster = Paster()

            let runner = Runner(
                recorder: recorder,
                transcriber: transcriber,
                paster: paster,
                minHoldMs: 200,
                onStateChange: { [weak self] state in
                    Task { @MainActor in self?.applyRunnerState(state) }
                }
            )
            self.recorder = recorder
            self.transcriber = transcriber
            self.runner = runner
            // Hotkey start is gated on permissions in applyPermissionSnapshot.
            if uiState != .permissionNeeded { tryStartHotkey() }
            if uiState == .loadingModel { uiState = .idle }
        } catch {
            Logger.app.error("bootstrap failed: \(error.localizedDescription)")
            self.lastError = error.localizedDescription
            self.uiState = .fatalError
        }
    }

    func quit() {
        runner?.shutdown()
        hotkey?.stop()
        NSApplication.shared.terminate(nil)
    }

    var icon: String {
        switch uiState {
        case .loadingModel:     return "hourglass"
        case .idle:             return "mic"
        case .recording:        return "mic.fill"
        case .transcribing:     return "waveform"
        case .permissionNeeded: return "exclamationmark.triangle"
        case .fatalError:       return "exclamationmark.octagon"
        }
    }

    // MARK: - Private

    private func tryStartHotkey() {
        guard let runner, hotkey == nil else { return }
        let hk = Hotkey { event in
            switch event {
            case .press:   runner.onPress()
            case .release: runner.onRelease()
            }
        }
        do {
            try hk.start()
            self.hotkey = hk
            Logger.app.info("hotkey started")
        } catch {
            Logger.app.error("hotkey start failed: \(error.localizedDescription)")
            self.uiState = .permissionNeeded
            self.permissionMessage = "Grant Accessibility and Input Monitoring to Mumblur."
        }
    }

    private func applyPermissionSnapshot(_ snap: PermissionsCoordinator.Snapshot) {
        if !snap.allGranted {
            uiState = .permissionNeeded
            var missing: [String] = []
            if snap.microphone != .granted        { missing.append("Microphone") }
            if snap.accessibility != .granted     { missing.append("Accessibility") }
            if snap.inputMonitoring != .granted   { missing.append("Input Monitoring") }
            permissionMessage = "Grant: " + missing.joined(separator: ", ")
            return
        }
        permissionMessage = nil
        // All granted — start hotkey if we have a runner.
        if runner != nil && hotkey == nil {
            tryStartHotkey()
        }
        if uiState == .permissionNeeded { uiState = .idle }
    }

    private func applyRunnerState(_ s: Runner.State) {
        switch s {
        case .idle:         uiState = .idle
        case .recording:    uiState = .recording
        case .stopping:     uiState = .transcribing
        case .transcribing: uiState = .transcribing
        }
    }
}
```

- [ ] **Step 3: Re-generate the Xcode project**

Run: `xcodegen generate`

- [ ] **Step 4: Build**

Run: `xcodebuild build -project Mumblur.xcodeproj -scheme Mumblur -destination 'platform=macOS' -quiet`
Expected: builds successfully.

- [ ] **Step 5: Run harness**

Run: `scripts/verify_task.sh 10`
Expected: `Task 10 OK`.

- [ ] **Step 6: Commit**

Run:
```bash
git add App/
git commit -m "feat(app): PermissionsCoordinator with mandatory 2s re-check timer"
```

---

## Task 11: `build_app.sh` + entitlements

**Files:**
- Create: `scripts/build_app.sh`
- Create: `App/Resources/Mumblur.entitlements`
- Modify: `project.yml` to reference the entitlements file

- [ ] **Step 1: Write the entitlements file**

Write `App/Resources/Mumblur.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 2: Update `project.yml` to reference entitlements**

Modify `project.yml`. In the `Mumblur` target's `settings.base`, add:

```yaml
        CODE_SIGN_ENTITLEMENTS: App/Resources/Mumblur.entitlements
```

The full target stanza should now read:

```yaml
targets:
  Mumblur:
    type: application
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: App
        excludes:
          - Resources/Info.plist
          - Resources/Mumblur.entitlements
    resources:
      - path: App/Resources/Assets.xcassets
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: world.questable.mumblur
        PRODUCT_NAME: Mumblur
        INFOPLIST_FILE: App/Resources/Info.plist
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGN_ENTITLEMENTS: App/Resources/Mumblur.entitlements
        ENABLE_HARDENED_RUNTIME: YES
        SWIFT_STRICT_CONCURRENCY: complete
        LD_RUNPATH_SEARCH_PATHS:
          - "@executable_path/../Frameworks"
    dependencies:
      - package: MumblurCore
        product: MumblurCore
```

Then regenerate: `xcodegen generate`.

- [ ] **Step 3: Write `build_app.sh`**

Write `scripts/build_app.sh`:

```bash
#!/usr/bin/env bash
# Build Mumblur.app (Release), already ad-hoc-signed by Xcode, and optionally
# install to /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED="$ROOT/build"
xcodebuild \
    -project Mumblur.xcodeproj \
    -scheme Mumblur \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS' \
    build

APP="$DERIVED/Build/Products/Release/Mumblur.app"
if [[ ! -d "$APP" ]]; then
    echo "FAIL: build did not produce $APP" >&2
    exit 1
fi
echo "Built: $APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature' || true

if [[ "${1-}" == "--install" ]]; then
    rsync -a --delete "$APP" /Applications/
    echo "Installed to /Applications/Mumblur.app"
fi
```

Make executable:
```bash
chmod +x scripts/build_app.sh
```

- [ ] **Step 4: Smoke build**

Run: `scripts/build_app.sh`
Expected: builds without error; final lines show `Identifier=world.questable.mumblur` and `Signature=adhoc`.

- [ ] **Step 5: Run harness**

Run: `scripts/verify_task.sh 11`
Expected: `Task 11 OK`.

- [ ] **Step 6: Commit**

Run:
```bash
git add scripts/build_app.sh App/Resources/Mumblur.entitlements project.yml Mumblur.xcodeproj/
git commit -m "feat(build): build_app.sh + audio-input entitlement"
```

---

## Task 12: Manual smoke test runbook

Not automated — the runbook for proving end-to-end behavior on the real machine.

- [ ] **Step 1: Install the app**

Run: `scripts/build_app.sh --install`
Expected: `Installed to /Applications/Mumblur.app`.

- [ ] **Step 2: Launch from Spotlight**

Press ⌘Space, type `Mumblur`, Enter. The menu bar should show a `hourglass` icon briefly (model loading) then transition to either:
- `mic` (idle, all permissions already granted), or
- `exclamationmark.triangle` (permissions needed — most likely on first launch).

- [ ] **Step 3: Grant permissions through the OS dialogs**

For each of Microphone, Accessibility, and Input Monitoring: when prompted by macOS, click "Open System Settings" and toggle Mumblur **ON**. You do NOT need to quit and relaunch — the 2 s re-check timer picks up the new state automatically. Within a few seconds of granting all three, the menu bar icon should switch to `mic` (idle).

- [ ] **Step 4: Dictate a short sentence**

Open TextEdit, click into a new empty document, hold **Right Option**, say "the quick brown fox jumps over the lazy dog," release.

Expected: within ~1 s of release, the sentence appears at the cursor. The menu bar icon flashes through `mic.fill` (recording) → `waveform` (transcribing) → `mic` (idle).

- [ ] **Step 5: Dictate a longer passage**

Hold Right Option for ~15 s, speak, release. Transcript should appear within ~1 s.

- [ ] **Step 6: Tap briefly (min-hold guard)**

Tap Right Option for < 200 ms. Nothing should happen; menu bar icon flashes recording then idle.

- [ ] **Step 7: Single-flight rejection**

Hold Right Option for ~10 s, release. Immediately (while the `waveform` icon is showing) tap Right Option again briefly.

Expected: the second tap is rejected; the first transcript still pastes. Verify via `log stream --predicate 'subsystem == "world.questable.mumblur"' --info` running in another terminal — you should see a line like `press ignored (state=transcribing)`.

- [ ] **Step 8: Left + Right Option distinction**

Hold Left Option, then while still holding Left Option, hold Right Option, speak, release Right Option (keep Left Option held). Release Left Option last.

Expected: recording starts only on Right Option down, stops only on Right Option up. Left Option is ignored.

- [ ] **Step 9: Quit cleanly**

Click the menu bar icon → "Quit Mumblur".

Expected: process exits within 1 s, no traceback in Console.

- [ ] **Step 10: Run harness one final time**

Run: `scripts/verify_task.sh 12`
Expected: `Task 12 OK`.

- [ ] **Step 11: Capture any runbook findings**

If the smoke test surfaced unexpected behavior (a permission that didn't prompt, an icon that didn't update, a delay longer than expected), capture them as a short follow-up section in the spec's open-questions list or as new GitHub issues / TODO files. Then commit if you wrote anything down.

---

## Definition of Done

- All Tasks 0–11 committed; commit log shows the expected sequence.
- `scripts/verify_task.sh 11` passes from a fresh clone after `xcodegen generate` + `xcodebuild`.
- `(cd MumblurCore && swift test)` passes (all fast unit tests across all modules).
- `MUMBLUR_RUN_SLOW=1 (cd MumblurCore && swift test --filter TranscriberTests/testIntegration_transcribesHelloWorldFixture)` passes once on the dev machine (real-model integration test).
- Task 12 manual smoke test passes end-to-end:
  - All three OS permission dialogs fired and were granted.
  - Dictation works in TextEdit and one other app of your choice.
  - Single-flight rejection observed (log line + UI behavior).
  - Left/Right Option distinction works.
- Mumblur.app is installed in `/Applications/`.
- The Python implementation under `src/mumbler/` is left intact as a reference; the Swift implementation lives under `MumblurCore/` + `App/`.
