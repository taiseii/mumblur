#!/usr/bin/env bash
# Verification harness for mumbler. Run `scripts/verify_task.sh N` after Task N.
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
py()        { uv run python -c "$1" >/dev/null; }

case "$TASK" in
    0)
        need_file scripts/verify_task.sh
        [[ -x scripts/verify_task.sh ]] || fail "scripts/verify_task.sh is not executable"
        ;;
    1)
        need_dir src/mumbler
        need_file src/mumbler/__init__.py
        need_dir tests
        need_file tests/__init__.py
        absent main.py
        absent get_started.py
        need_file pyproject.toml
        grep -q '"modal' pyproject.toml && fail "modal dependency should be removed from pyproject.toml"
        grep -q 'pywhispercpp' pyproject.toml || fail "pywhispercpp missing from pyproject.toml"
        py "import mumbler; assert mumbler.__version__"
        ;;
    2)
        bash "$0" 1
        need_file src/mumbler/audio.py
        py "from mumbler.audio import AudioRecorder, SAMPLE_RATE; assert SAMPLE_RATE == 16000"
        uv run pytest tests/test_audio.py -v
        ;;
    3)
        bash "$0" 2
        need_file src/mumbler/paste.py
        py "from mumbler.paste import paste"
        uv run pytest tests/test_paste.py -v
        ;;
    4)
        bash "$0" 3
        need_file src/mumbler/transcribe.py
        need_file tests/fixtures/hello_world.wav
        need_file scripts/make_test_fixture.py
        need_file scripts/download_model.sh
        [[ -x scripts/download_model.sh ]] || fail "scripts/download_model.sh is not executable"
        py "from mumbler.transcribe import Transcriber"
        uv run pytest tests/test_transcribe.py -v -m "not slow"
        ;;
    5)
        bash "$0" 4
        need_file src/mumbler/hotkey.py
        py "from mumbler.hotkey import Dispatcher, listen"
        uv run pytest tests/test_hotkey.py -v
        ;;
    6)
        bash "$0" 5
        need_file src/mumbler/cli.py
        py "from mumbler.cli import Runner, main"
        # Console script registered
        uv run python -c "from importlib.metadata import entry_points; \
            assert any(ep.name == 'mumbler' for ep in entry_points(group='console_scripts'))"
        uv run pytest -v -m "not slow"
        ;;
    7)
        bash "$0" 6
        need_file README.md
        grep -q 'large-v3-turbo-q5_0' README.md || fail "README must reference large-v3-turbo-q5_0"
        grep -q -- '--hotkey' README.md       || fail "README must document --hotkey"
        grep -q -- '--min-hold-ms' README.md  || fail "README must document --min-hold-ms"
        ;;
    8)
        bash "$0" 7
        uv run pytest -v -m "not slow"
        ;;
    *)
        fail "unknown task: $TASK"
        ;;
esac

echo "Task $TASK OK"
