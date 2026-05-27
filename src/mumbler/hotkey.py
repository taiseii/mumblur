"""Global push-to-talk hotkey listener.

Split in two:
- `Dispatcher` — pure state machine, no pynput involvement, unit-testable.
- `listen()` — wires Dispatcher to pynput.keyboard.Listener and blocks.

Callbacks fire on pynput's listener thread. Callers should make on_press /
on_release cheap; long work (Whisper, paste) should happen on a worker.
"""

from __future__ import annotations

from typing import Any, Callable


class Dispatcher:
    """Maps raw key events to push/release callbacks for one target key.

    `target_key` must be `==`-comparable to whatever pynput hands us
    (in practice, a `pynput.keyboard.Key` enum value).
    """

    def __init__(
        self,
        target_key: Any,
        on_press: Callable[[], None],
        on_release: Callable[[], None],
    ) -> None:
        self._target = target_key
        self._on_press = on_press
        self._on_release = on_release
        self._held = False

    def handle_press(self, key: Any) -> None:
        if key != self._target:
            return
        if self._held:
            return  # ignore OS auto-repeat
        self._held = True
        self._on_press()

    def handle_release(self, key: Any) -> None:
        if key != self._target:
            return
        if not self._held:
            return
        self._held = False
        self._on_release()


def listen(
    on_press: Callable[[], None],
    on_release: Callable[[], None],
    target_key: Any | None = None,
) -> None:
    """Block forever, firing `on_press`/`on_release` for the target key.

    Uses `pynput.keyboard.Listener`. Requires macOS Accessibility permission;
    if missing, pynput raises and we let the exception propagate so cli.main()
    can surface a friendly message.
    """
    from pynput import keyboard

    if target_key is None:
        target_key = keyboard.Key.alt_r

    dispatcher = Dispatcher(target_key, on_press, on_release)

    with keyboard.Listener(
        on_press=dispatcher.handle_press,
        on_release=dispatcher.handle_release,
    ) as listener:
        listener.join()
