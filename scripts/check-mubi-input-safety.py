#!/usr/bin/env python3
"""Fast, source-level safety guard for MoveBit's native X11 Mubi surface.

The opaque/clickable event region is *not* the same as GTK's can-target flag.
This checks essential fail-safe invariants before the costly native host build.
It is intentionally NOT a substitute for actual X11 input/Focus smoke tests.
"""
from __future__ import annotations

import argparse
from pathlib import Path


REQUIRED = {
    "Native empty pointer input region": (
        "cairo_region_create()",
        "gdk_surface_set_input_region(surface, empty_input)",
        "cairo_region_destroy(empty_input)",
    ),
    "Fallback when input shape is unsupported": (
        "gdk_display_supports_input_shapes(display)",
        "g_state.api->set_host_capability_async(g_state.mubi_x11",
    ),
    "Not keyboard-focusable": (
        "gtk_widget_set_can_focus(window, FALSE)",
        "gtk_widget_set_focusable(window, FALSE)",
    ),
    "Display without GTK present-focus request": (
        "gtk_widget_set_visible(GTK_WIDGET(s.mubi_window), TRUE)",
    ),
    "Wayland remains notification-only": (
        "if (!g_state.mubi_x11) return;",
    ),
}
FORBIDDEN = {
    "GTK present may request keyboard focus on the floating pet":
        "gtk_window_present(s.mubi_window)",
    "Native input region NULL means entire pet window intercepts pointer":
        "gdk_surface_set_input_region(surface, nullptr)",
}


def verify(source: str) -> list[str]:
    errors = [
        f"{label}: missing {part!r}"
        for label, parts in REQUIRED.items()
        for part in parts
        if part not in source
    ]
    errors.extend(
        f"{label}: found {part!r}"
        for label, part in FORBIDDEN.items()
        if part in source
    )
    return errors


def self_test(source: str) -> None:
    assert not verify(source), "expected valid source"
    for parts in REQUIRED.values():
        for part in parts:
            assert verify(source.replace(part, "", 1)), f"missed removal: {part}"
    for part in FORBIDDEN.values():
        assert verify(source + "\n" + part), f"missed regression: {part}"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    source = (Path(__file__).resolve().parent.parent / "linux/src/main.cpp").read_text(
        encoding="utf-8"
    )
    errors = verify(source)
    if errors:
        raise SystemExit("Mubi X11 input safety regression:\n" + "\n".join(errors))
    if args.self_test:
        self_test(source)
    print("Mubi X11 source-level input-safety checks PASS (not runtime acceptance)")
