#!/usr/bin/env python3
"""Exercise the native accessibility bridge against a real Servo document."""

import ctypes
import json
from pathlib import Path
import sys
import time


def main(library_path):
    library = ctypes.CDLL(str(Path(library_path).resolve()))

    def bind(name, result, *args):
        function = getattr(library, f"flutter_servo_{name}")
        function.restype = result
        function.argtypes = args
        return function

    pointer = ctypes.c_void_p
    string = ctypes.c_char_p
    boolean = ctypes.c_bool
    dimension = ctypes.c_uint32
    new = bind("session_new", pointer, string, string, string)
    free = bind("session_free", None, pointer)
    load = bind("session_set_html", boolean, pointer, string)
    render = bind("session_render_rgba", boolean, pointer, dimension, dimension,
                  pointer, ctypes.c_size_t)
    take_event = bind("session_take_control_event", pointer, pointer)
    free_event = bind("control_event_free", None, pointer)
    respond = bind("session_control_response", boolean, pointer, string)

    session = new(None, None, None)
    if not session:
        raise RuntimeError("Servo session creation failed")
    pixels = ctypes.create_string_buffer(480 * 300 * 4)

    def send(**event):
        return respond(session, json.dumps(event).encode())

    def wait_for(predicate, description):
        deadline = time.monotonic() + 15
        last_nodes = None
        while time.monotonic() < deadline:
            render(session, 480, 300, pixels, len(pixels))
            while event := take_event(session):
                try:
                    message = json.loads(ctypes.string_at(event))
                finally:
                    free_event(event)
                if message["type"] == "accessibilityTree":
                    last_nodes = message["nodes"]
                    found = predicate(last_nodes)
                    if found is not None:
                        return found
            time.sleep(0.02)
        raise AssertionError(f"No matching accessibility update for {description}: {last_nodes}")

    try:
        assert send(type="accessibilityEnabled", enabled=True)
        assert load(session, b"""
            <h1>Accessibility probe</h1>
            <a href="data:text/html,%3Cp%3EActivated%3C/p%3E">Launch test</a>
        """)

        def initial_page(nodes):
            if not any(node["role"] == "Heading" and node["label"] == "Accessibility probe"
                       for node in nodes):
                return None
            return next((node for node in nodes if node["role"] == "Link"
                         and node["label"] == "Launch test" and node["clickable"]), None)

        link = wait_for(initial_page, "the heading and link")
        assert send(type="accessibilityAction", id=link["id"], action="Click")
        wait_for(lambda nodes: next((node for node in nodes if node["value"] == "Activated"), None),
                 "the destination document after link activation")
        assert not send(type="accessibilityAction", id=link["id"], action="Click")
        assert send(type="accessibilityEnabled", enabled=False)
        wait_for(lambda nodes: True if not nodes else None, "the cleared tree")
        assert not send(type="accessibilityAction", id=link["id"], action="Click")
        print("Servo accessibility heading, action dispatch, and deactivation passed")
    finally:
        free(session)


if __name__ == "__main__":
    main(sys.argv[1])
