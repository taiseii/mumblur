"""Generate tests/fixtures/hello_world.wav using macOS `say`.

Run once; the resulting WAV is committed so the test fixture is reproducible.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

FIXTURE = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "hello_world.wav"


def main() -> int:
    if shutil.which("say") is None:
        print("`say` not found; this script requires macOS.", file=sys.stderr)
        return 1
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    aiff = FIXTURE.with_suffix(".aiff")
    subprocess.run(
        ["say", "-v", "Samantha", "-o", str(aiff), "hello world"],
        check=True,
    )
    subprocess.run(
        [
            "afconvert",
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            str(aiff),
            str(FIXTURE),
        ],
        check=True,
    )
    aiff.unlink()
    print(f"wrote {FIXTURE} ({FIXTURE.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
