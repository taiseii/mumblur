# Contributing to Mumblur

Thanks for considering a contribution. Mumblur is small enough that one well-aimed PR makes a visible difference. Please read this once before opening a non-trivial change.

## Quick setup

```bash
brew install xcodegen
git clone https://github.com/taiseii/mumblur.git
cd mumblur
xcodegen generate
cd MumblurCore && swift test     # 145+ tests, < 1 s
cd ..
scripts/build_app.sh --install   # builds + ad-hoc signs + drops in /Applications
open /Applications/Mumblur.app
```

Requirements: macOS 14+, Apple Silicon recommended, Xcode 16+, ~1 GB free for the WhisperKit model.

## Project layout

```
App/                              SwiftUI menu-bar target (@MainActor, view models)
  Settings/                       Tabbed Settings panes + ViewModels/
  AppCoordinator.swift            Orchestrator: bootstrap, swap, bridging
  MenuBarContent.swift            Menu bar UI

MumblurCore/                      Standalone Swift package — testable, no UI
  Sources/MumblurCore/
    AudioRecorder.swift           AVAudioEngine capture, 16 kHz mono
    AudioInputs.swift             Core Audio device enumeration + apply
    Transcriber.swift             WhisperKit actor + ServingSnapshot pipeline
    LLMEditor.swift               OpenAI-compatible HTTP client (fail-open, hard timeout)
    FewShot.swift                 Prompt augmentation from saved corrections
    Runner.swift                  Press/release state machine; pipeline glue
    TranscriptPostProcessor.swift Regex/literal replacement rules
    Storage/                      GRDB + SQLite; versioned migrations
  Tests/MumblurCoreTests/         XCTest

scripts/
  build_app.sh                    Release build + ad-hoc sign + optional --install
  package_release.sh              Zip the .app for a GitHub Release upload
  verify_task.sh                  Per-task build/test harness
```

## Workflow

### Test-driven, end to end

Production code without a failing test that came first does not land. Concretely:

1. Write the smallest failing test that expresses the behavior you want.
2. Run it, confirm the failure is for the expected reason (missing API, not a typo).
3. Write the minimum code to make it pass.
4. Refactor on green.

The existing suite (`145+` tests, `< 1 s`) is the bar — keep it pristine. Hardware-coupled paths (Core Audio device routing, WhisperKit decoding) are verified by integration, but every pure function gets a test.

### Branches and commits

- Branch off `main`. Name it `feat/short-thing`, `fix/short-thing`, `docs/...`.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for the subject line: `feat(scope): …`, `fix(core): …`, `docs: …`, `refactor: …`.
- Keep commits focused. If a diff bundles two ideas, split it. Don't squash mid-PR feedback into a misleading subject.
- The commit body explains *why*. The diff already shows *what*.

### Pull requests

- One topic per PR. Anything over ~400 lines of production code should probably be split.
- Tests are required for behavior changes. Coverage for the regression you're fixing is the minimum bar.
- If you touch a UI surface, run the app locally (`scripts/build_app.sh --install`) and describe what you saw. Tests can't verify SwiftUI rendering.
- Diagnostic `.notice`-level logs at major pipeline gates are appreciated; `.info` doesn't persist by default on macOS and disappears from `log show`.

### Style

- Swift 6, strict concurrency. Actor isolation is real; reach for `@MainActor` only when you mean it.
- Defaulted protocol params (`editor: any TranscriptEditing = NoOpEditor()`) over `nil`-able implementations.
- Reading `~/.claude/projects/...` memory is fine but not required; the code is the source of truth.

## Logs while testing

```bash
log stream --predicate 'subsystem == "world.questable.mumblur"' --info --debug
```

Or for persisted .notice-level only (works after the fact via `log show`):

```bash
log show --predicate 'subsystem == "world.questable.mumblur"' --last 10m --style compact
```

## Reporting bugs

Open an issue with: macOS version, Apple Silicon vs. Intel, the exact dictation flow that broke, and the relevant `log show` excerpt (last 5 min, filtered to the subsystem above). A SQL dump of the offending transcript row helps for LLM-edit issues:

```bash
sqlite3 "$HOME/Library/Application Support/Mumblur/mumblur.sqlite" \
  "SELECT id, length(raw_text), length(final_text), substr(raw_text,1,80) FROM transcript ORDER BY id DESC LIMIT 5"
```

## Code of conduct

Be kind. Disagree with the code, not the person. Assume good faith. If you wouldn't say it to a colleague in a one-on-one, don't write it in a PR review.

## License

By contributing, you agree your work is released under the project's [MIT license](LICENSE).
