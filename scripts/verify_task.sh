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
    13)
        bash "$0" 12
        need_file MumblurCore/Sources/MumblurCore/Storage/Database.swift
        need_file MumblurCore/Sources/MumblurCore/Storage/MigrationsV1.swift
        need_file MumblurCore/Tests/MumblurCoreTests/Storage/DatabaseTests.swift
        grep -q 'GRDB.swift' MumblurCore/Package.swift || fail "GRDB not in Package.swift"
        core_test
        ;;
    14)
        bash "$0" 13
        need_file MumblurCore/Sources/MumblurCore/Profile.swift
        need_file MumblurCore/Sources/MumblurCore/ReplacementRule.swift
        need_file MumblurCore/Sources/MumblurCore/PromptPayload.swift
        need_file MumblurCore/Sources/MumblurCore/ServingSnapshot.swift
        need_file MumblurCore/Sources/MumblurCore/TranscriptPostProcessor.swift
        need_file MumblurCore/Tests/MumblurCoreTests/TranscriptPostProcessorTests.swift
        core_test
        ;;
    15)
        bash "$0" 14
        need_file MumblurCore/Sources/MumblurCore/Storage/SettingsStore.swift
        need_file MumblurCore/Tests/MumblurCoreTests/Storage/SettingsStoreTests.swift
        core_test
        ;;
    16)
        bash "$0" 15
        need_file MumblurCore/Sources/MumblurCore/Storage/TranscriptStore.swift
        need_file MumblurCore/Sources/MumblurCore/Storage/AudioStore.swift
        need_file MumblurCore/Tests/MumblurCoreTests/Storage/TranscriptStoreTests.swift
        need_file MumblurCore/Tests/MumblurCoreTests/Storage/AudioStoreTests.swift
        core_test
        ;;
    17)
        bash "$0" 16
        need_file MumblurCore/Sources/MumblurCore/PromptBuilder.swift
        need_file MumblurCore/Tests/MumblurCoreTests/PromptBuilderTests.swift
        need_file MumblurCore/Tests/MumblurCoreTests/WhisperKitSpikeTests.swift
        core_test
        ;;
    18)
        bash "$0" 17
        grep -q 'actor Transcriber' MumblurCore/Sources/MumblurCore/Transcriber.swift
        grep -q 'func commit(snapshot:' MumblurCore/Sources/MumblurCore/Transcriber.swift
        core_test
        ;;
    19)
        bash "$0" 18
        need_file MumblurCore/Sources/MumblurCore/ModelManager.swift
        need_file MumblurCore/Tests/MumblurCoreTests/ModelManagerTests.swift
        grep -q 'generation &+= 1' MumblurCore/Sources/MumblurCore/ModelManager.swift \
            || fail "ModelManager missing generation guard"
        core_test
        ;;
    20)
        bash "$0" 19
        grep -q 'protocol DictationPersisting' MumblurCore/Sources/MumblurCore/Runner.swift
        grep -q 'postProcessor.apply' MumblurCore/Sources/MumblurCore/Runner.swift
        grep -q 'await paster.paste' MumblurCore/Sources/MumblurCore/Runner.swift
        core_test
        ;;
    21.5)
        bash "$0" 20
        need_file MumblurCore/Sources/MumblurCore/Storage/RetentionAwarePersister.swift
        need_file MumblurCore/Tests/MumblurCoreTests/Storage/RetentionAwarePersisterTests.swift
        core_test
        ;;
    21)
        bash "$0" 21.5
        grep -q '\.swappingModel' App/AppCoordinator.swift || fail "missing .swappingModel state"
        grep -q 'switchActiveProfile' App/AppCoordinator.swift
        app_build
        ;;
    22)
        bash "$0" 21
        need_file MumblurCore/Sources/MumblurCore/WERNormalizer.swift
        need_file MumblurCore/Sources/MumblurCore/Tuning/WERCalculator.swift
        need_file MumblurCore/Tests/MumblurCoreTests/WERTests.swift
        core_test
        ;;
    23)
        bash "$0" 22
        need_file MumblurCore/Sources/MumblurCore/Tuning/CalibrationScripts.swift
        need_file MumblurCore/Sources/MumblurCore/Tuning/ErrorMiner.swift
        need_file MumblurCore/Sources/MumblurCore/Tuning/SuggestionGenerator.swift
        core_test
        ;;
    24)
        bash "$0" 23
        need_file MumblurCore/Sources/MumblurCore/Tuning/CalibrationController.swift
        grep -q 'func setSuspended' MumblurCore/Sources/MumblurCore/Runner.swift \
            || fail "Runner missing setSuspended(on:)"
        core_test
        ;;
    25)
        bash "$0" 24
        need_file App/Settings/SettingsScene.swift
        need_file App/Settings/OpenSettingsTrampoline.swift
        need_file App/Settings/GeneralSettingsView.swift
        need_file App/Settings/ProfilesSettingsView.swift
        need_file App/Settings/ViewModels/ProfilesViewModel.swift
        need_file App/Tests/Settings/ProfilesViewModelTests.swift
        grep -q 'Settings {' App/MumblurApp.swift || fail "MumblurApp missing Settings scene"
        grep -q 'OpenSettingsTrampoline' App/MumblurApp.swift \
            || fail "MumblurApp missing the hidden Window trampoline"
        awk '
            /Window\(.OpenSettingsTrampoline/  { if (!w) w=NR }
            /MenuBarExtra/                     { if (!m) m=NR }
            /^[[:space:]]*Settings[[:space:]]*\{/ { if (!s) s=NR }
            END { if (w && m && s && w<m && m<s) exit 0; else exit 1 }
        ' App/MumblurApp.swift || fail "MumblurApp scene order must be Window -> MenuBarExtra -> Settings"
        app_build
        ;;
    26)
        bash "$0" 25
        need_file App/Settings/ModelsSettingsView.swift
        need_file App/Settings/TuningSettingsView.swift
        need_file App/Settings/DataSettingsView.swift
        need_file App/Settings/AboutSettingsView.swift
        need_file App/Settings/ViewModels/ModelsViewModel.swift
        need_file App/Settings/ViewModels/TuningViewModel.swift
        need_file App/Settings/ViewModels/DataViewModel.swift
        need_file App/Tests/Settings/ModelsViewModelTests.swift
        need_file App/Tests/Settings/TuningViewModelTests.swift
        need_file App/Tests/Settings/DataViewModelTests.swift
        grep -q 'ModelsSettingsView' App/Settings/SettingsScene.swift
        grep -q 'TuningSettingsView' App/Settings/SettingsScene.swift
        grep -q 'DataSettingsView'   App/Settings/SettingsScene.swift
        grep -q 'AboutSettingsView'  App/Settings/SettingsScene.swift
        app_build
        ;;
    27)
        bash "$0" 26
        grep -q 'SMAppService' App/AppCoordinator.swift || fail "missing SMAppService wiring"
        grep -q 'Settings…' App/MenuBarContent.swift     || fail "missing Settings… item"
        grep -q 'openSettingsRequest' App/MenuBarContent.swift \
            || fail "menu-bar Settings… must post .openSettingsRequest (not NSApp.sendAction)"
        grep -q 'Profile: ' App/MenuBarContent.swift     || fail "missing profile switcher"
        app_build
        ;;
    28)
        bash "$0" 27
        core_test
        app_build
        ;;
    *)
        fail "unknown task: $TASK"
        ;;
esac

echo "Task $TASK OK"
