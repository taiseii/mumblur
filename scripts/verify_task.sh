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
