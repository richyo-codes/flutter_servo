#!/usr/bin/env python3
"""Exercise the native accessibility bridge against a real Servo document."""

import ctypes
import json
from pathlib import Path
import sys
import tempfile
import time


def main(library_path):
    library_path = Path(library_path).resolve()
    angle = []
    if sys.platform == "win32":
        # Surfman calls LoadLibraryA("libEGL.dll") later. Keep the exact
        # bundled ANGLE pair loaded so that lookup works inside python.exe.
        for name in ("libGLESv2.dll", "libEGL.dll"):
            dll = library_path.with_name(name)
            try:
                angle.append(ctypes.WinDLL(str(dll)))
            except OSError as error:
                raise RuntimeError(f"Could not preload bundled ANGLE DLL: {dll}") from error
    library = ctypes.CDLL(str(library_path))

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
    button = bind("session_notify_mouse_button", boolean, pointer,
                  ctypes.c_int32, ctypes.c_int32, ctypes.c_uint8, boolean)

    session = new(None, None, None)
    if not session:
        raise RuntimeError("Servo session creation failed")
    pixels = ctypes.create_string_buffer(480 * 300 * 4)

    def send(**event):
        return respond(session, json.dumps(event).encode())

    def click_painted_control(rgb, description):
        # Accessibility updates can precede the compositor's new scene. Click
        # once, only after this fixture (not its predecessor) paints the target.
        x, y = 400, 40
        offset = (480 * y + x) * 4
        deadline = time.monotonic() + 15
        last = None
        while time.monotonic() < deadline:
            if render(session, 480, 300, pixels, len(pixels)):
                last = pixels[offset:offset + 3]
                if last == rgb:
                    assert button(session, x, y, 0, True)
                    assert button(session, x, y, 0, False)
                    return
            time.sleep(0.02)
        raise AssertionError(f"{description} never painted at {(x, y)}: last RGB {last!r}")

    def wait_for(predicate, description, event_type="accessibilityTree"):
        deadline = time.monotonic() + 15
        last_nodes = None
        while time.monotonic() < deadline:
            render(session, 480, 300, pixels, len(pixels))
            while event := take_event(session):
                try:
                    message = json.loads(ctypes.string_at(event))
                finally:
                    free_event(event)
                if event_type is None or message["type"] == event_type:
                    last_nodes = message["nodes"] if event_type == "accessibilityTree" else message
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
        policy = "--navigation-policy" in sys.argv[2:]
        if policy:
            assert send(type="requireNavigationPolicy")
            assert send(type="accessibilityAction", id=link["id"], action="Click")
            denied = wait_for(lambda e: e, "first navigation decision", "navigationRequest")
            assert denied["url"].startswith("data:text/html,")
            assert send(type="navigationDecision", id=denied["id"], allow=False)
            assert not send(type="navigationDecision", id=denied["id"], allow=True)
            assert send(type="accessibilityAction", id=link["id"], action="Click")
            stalled = wait_for(lambda e: e, "unanswered navigation decision", "navigationRequest")
            # Simulate a stalled host; no frame pump or control poll during the pause.
            time.sleep(5.2)
            assert not send(type="navigationDecision", id=stalled["id"], allow=True)
        assert send(type="accessibilityAction", id=link["id"], action="Click")
        if policy:
            allowed = wait_for(lambda e: e, "second navigation decision", "navigationRequest")
            assert allowed["id"] != denied["id"]
            assert allowed["id"] != stalled["id"]
            assert send(type="navigationDecision", id=allowed["id"], allow=True)
        wait_for(lambda nodes: next((node for node in nodes if node["value"] == "Activated"), None),
                 "the destination document after link activation")
        assert not send(type="accessibilityAction", id=link["id"], action="Click")
        assert send(type="accessibilityEnabled", enabled=False)
        wait_for(lambda nodes: True if not nodes else None, "the cleared tree")
        assert not send(type="accessibilityAction", id=link["id"], action="Click")
        print("Servo accessibility heading, action dispatch, and deactivation passed")
        if "--popup" in sys.argv[2:]:
            assert send(type="accessibilityEnabled", enabled=True)
            assert load(session, b"""
              <button style="appearance:none;background:#267351;position:fixed; inset:0; width:100%;height:100%"
                onclick="document.title = window.open('about:blank') === null
                    ? 'popup denied' : 'popup created'">Request popup</button>
            """)
            wait_for(lambda nodes: next((n for n in nodes if n["value"] == "Request popup"), None),
                     "the popup button")
            click_painted_control(bytes.fromhex("267351"), "popup button")
            seen = set()

            def popup_result(message):
                if message["type"] == "popupBlocked":
                    seen.add("host")
                if message["type"] == "title":
                    assert message["title"] != "popup created"
                    if message["title"] == "popup denied":
                        seen.add("page")
                return True if seen == {"host", "page"} else None

            wait_for(popup_result, "blocked popup notification and null window handle", None)
            print("Servo popup denied in the page and reported to the host")
        if "--file-picker" not in sys.argv[2:]:
            return
        assert send(type="accessibilityEnabled", enabled=True)
        assert load(session, b"""
          <input type=file aria-label="Select fixture" style="background:#305796;position:fixed;inset:0;width:100%;height:100%">
          <script>document.querySelector('input').onchange = async e => {
            const f = e.target.files[0];
            document.title = f.name + ':' + await f.text();
          };</script>
        """)
        wait_for(lambda nodes: True if any(n.get("value") == "Choose file" for n in nodes)
                 else None, "the file input")
        click_painted_control(bytes.fromhex("305796"), "file input")
        picker = wait_for(lambda e: e, "the file picker", "filePicker")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "selected.txt"
            path.write_text("selected contents", encoding="utf-8")
            assert not send(type="filePicker", id=picker["id"] + 1, paths=[str(path)])
            assert send(type="filePicker", id=picker["id"], paths=[str(path)])
            assert not send(type="filePicker", id=picker["id"], paths=[str(path)])
            wait_for(lambda e: True if e.get("title") == "selected.txt:selected contents" else None,
                     "the selected file contents in the page", "title")
        print("Servo file picker selection and one-use reply passed")
    finally:
        free(session)


if __name__ == "__main__":
    main(sys.argv[1])
