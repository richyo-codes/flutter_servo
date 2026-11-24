"""Linux native regression: two visitors, one origin, one OS profile."""

import ctypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/forbidden")
            self.end_headers()
            return
        if self.path == "/forbidden":
            self.server.redirect_followed.set()
        script = """
          const held = localStorage.getItem('visitor');
          const cookie = document.cookie.includes('visitor=first');
          document.title = 'state:' + JSON.stringify([held, cookie, sessionStorage.getItem('visitor')]);
        """
        if self.path == "/write":
            script = """
              localStorage.setItem('visitor', 'first');
              sessionStorage.setItem('visitor', 'session');
              document.cookie = 'visitor=first; Path=/; Max-Age=3600';
              location.replace('/read');
            """
        elif self.path.partition("?")[0] != "/read":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(f"<!doctype html><script>{script}</script>".encode())


def visit(library, origin, mode):
    lib = ctypes.CDLL(library)
    ptr, string, flag, uint = (ctypes.c_void_p, ctypes.c_char_p,
                               ctypes.c_bool, ctypes.c_uint32)

    def bind(name, result, *args):
        fn = getattr(lib, "flutter_servo_" + name)
        fn.restype, fn.argtypes = result, args
        return fn

    new = bind("session_new", ptr, string, string, string)
    load = bind("session_set_url", flag, ptr, string)
    render = bind("session_render_rgba", flag, ptr, uint, uint, ptr, ctypes.c_size_t)
    event = bind("session_take_control_event", ptr, ptr)
    release = bind("control_event_free", None, ptr)
    respond = bind("session_control_response", flag, ptr, string)
    free = bind("session_free", None, ptr)
    session = new(None, None, b"127.0.0.1")
    if not session:
        raise RuntimeError("Cannot create native session")
    try:
        write = mode != "read"
        clearing = False
        site_step = 0
        url = origin + ("/write" if write else "/read")
        if mode == "redirect":
            assert respond(session, b'{"type":"requireNavigationPolicy"}')
            url = origin + "/redirect"
        if not load(session, url.encode()):
            raise AssertionError(f"Fixture load rejected: {url}")
        pixels = ctypes.create_string_buffer(160 * 120 * 4)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            render(session, 160, 120, pixels, len(pixels))
            while raw := event(session):
                try:
                    message = json.loads(ctypes.string_at(raw))
                finally:
                    release(raw)
                if mode == "redirect" and message.get("type") == "redirectBlocked":
                    return
                if message == {"type": "cookiesCleared", "id": 7} and clearing:
                    assert load(session, (origin + "/read?cleared").encode())
                    continue
                title = message.get("title") or ""
                if message.get("type") == "title" and title.startswith("state:"):
                    actual = json.loads(title[6:])
                    expected = (["first", not clearing, "session"] if write and site_step < 2
                                else [None, False, None])
                    if actual != expected:
                        raise AssertionError(f"Expected {expected}, got {actual}")
                    if mode == "clear" and not clearing:
                        clearing = True
                        assert respond(session, b'{"type":"clearCookiesConfirmed","id":7}')
                        continue
                    if mode == "site" and site_step < 2:
                        if site_step == 0:
                            assert not respond(session, json.dumps(
                                {"type": "clearSiteData", "site": origin}).encode())
                        site = ("other.invalid", "127.0.0.1")[site_step]
                        assert respond(session, json.dumps({"type": "clearSiteData", "site": site}).encode())
                        site_step += 1
                        assert load(session, f"{origin}/read?step={site_step}".encode())
                        continue
                    return
            time.sleep(0.01)
        raise AssertionError("No storage result from the fixture document")
    finally:
        free(session)


def main(library):
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server, tempfile.TemporaryDirectory() as profile:
        server.redirect_followed = threading.Event()
        threading.Thread(target=server.serve_forever, daemon=True).start()
        origin = f"http://127.0.0.1:{server.server_port}"
        env = dict(os.environ, FLUTTER_SERVO_EPHEMERAL="1", TMPDIR=profile,
                   XDG_CONFIG_HOME=profile, XDG_DATA_HOME=profile, XDG_CACHE_HOME=profile)
        env.pop("FLUTTER_SERVO_ALLOWED_ORIGINS", None)
        try:
            for mode in ("write", "read", "clear", "site", "redirect"):
                subprocess.run([sys.executable, __file__, str(Path(library).resolve()),
                                origin, mode], env=env, timeout=30, check=True)
            assert not server.redirect_followed.is_set(), "Protected redirect reached destination"
        finally:
            server.shutdown()
    print("Visitor isolation, confirmed cookie deletion, and site-scoped web storage deletion passed")


if __name__ == "__main__":
    if len(sys.argv) == 4:
        visit(sys.argv[1], sys.argv[2], sys.argv[3])
    else:
        main(sys.argv[1])
