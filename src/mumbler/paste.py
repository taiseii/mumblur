"""Paste a string at the cursor in the active macOS app.

Writes the text to the pasteboard via `pbcopy`, then synthesizes a Cmd+V
keystroke via `pynput`. Empty / whitespace strings are skipped entirely.
"""

from __future__ import annotations

import subprocess
from typing import Callable


def _default_cmd_v() -> None:
    from pynput.keyboard import Controller, Key  # lazy import

    kb = Controller()
    with kb.pressed(Key.cmd):
        kb.press("v")
        kb.release("v")


def paste(text: str, send_cmd_v: Callable[[], None] = _default_cmd_v) -> None:
    if not text or not text.strip():
        return

    subprocess.run(
        ["pbcopy"],
        input=text,
        text=True,
        check=True,
    )
    send_cmd_v()
