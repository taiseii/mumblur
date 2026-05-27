"""Tests for mumbler.paste."""

from __future__ import annotations

import subprocess

from mumbler.paste import paste


class FakeKeystroke:
    def __init__(self):
        self.calls = []

    def __call__(self):
        self.calls.append("cmd+v")


def read_pasteboard() -> str:
    return subprocess.run(
        ["pbpaste"], capture_output=True, text=True, check=True
    ).stdout


def test_paste_writes_to_pasteboard_and_synthesizes_cmd_v():
    keystroke = FakeKeystroke()
    paste("hello mumbler", send_cmd_v=keystroke)

    assert read_pasteboard() == "hello mumbler"
    assert keystroke.calls == ["cmd+v"]


def test_paste_empty_string_is_noop():
    keystroke = FakeKeystroke()
    subprocess.run(["pbcopy"], input="sentinel", text=True, check=True)
    paste("", send_cmd_v=keystroke)
    assert read_pasteboard() == "sentinel"
    assert keystroke.calls == []


def test_paste_whitespace_only_is_noop():
    keystroke = FakeKeystroke()
    subprocess.run(["pbcopy"], input="sentinel2", text=True, check=True)
    paste("   \n\t  ", send_cmd_v=keystroke)
    assert read_pasteboard() == "sentinel2"
    assert keystroke.calls == []
