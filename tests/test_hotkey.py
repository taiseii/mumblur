"""Tests for mumbler.hotkey.Dispatcher."""

from __future__ import annotations

from mumbler.hotkey import Dispatcher


class _FakeKey:
    """Tiny stand-in for pynput.keyboard.Key with a stable identity."""

    def __init__(self, name: str):
        self.name = name

    def __eq__(self, other) -> bool:
        return isinstance(other, _FakeKey) and self.name == other.name

    def __hash__(self) -> int:
        return hash(self.name)


def test_press_then_release_of_target_key_fires_callbacks_in_order():
    target = _FakeKey("alt_r")
    events: list[str] = []
    d = Dispatcher(
        target_key=target,
        on_press=lambda: events.append("press"),
        on_release=lambda: events.append("release"),
    )

    d.handle_press(target)
    d.handle_release(target)

    assert events == ["press", "release"]


def test_unrelated_keys_are_ignored():
    target = _FakeKey("alt_r")
    other = _FakeKey("space")
    events: list[str] = []
    d = Dispatcher(
        target_key=target,
        on_press=lambda: events.append("press"),
        on_release=lambda: events.append("release"),
    )

    d.handle_press(other)
    d.handle_release(other)

    assert events == []


def test_repeated_presses_without_release_only_fire_press_once():
    target = _FakeKey("alt_r")
    events: list[str] = []
    d = Dispatcher(
        target_key=target,
        on_press=lambda: events.append("press"),
        on_release=lambda: events.append("release"),
    )

    d.handle_press(target)
    d.handle_press(target)
    d.handle_press(target)
    d.handle_release(target)

    assert events == ["press", "release"]


def test_release_without_press_is_ignored():
    target = _FakeKey("alt_r")
    events: list[str] = []
    d = Dispatcher(
        target_key=target,
        on_press=lambda: events.append("press"),
        on_release=lambda: events.append("release"),
    )

    d.handle_release(target)
    assert events == []
