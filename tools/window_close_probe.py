#!/usr/bin/env python3
"""Close only the launched example's X11 window using WM_DELETE_WINDOW.

No screenshots or input injection. Exercises GTK's real window-close path.
Usage: python3 tools/window_close_probe.py <bundle executable> [delay-seconds]
"""
import ctypes as c
import os
import subprocess
import sys
import time


class ClientMessage(c.Structure):
    _fields_ = [("type", c.c_int), ("serial", c.c_ulong),
                ("send_event", c.c_int), ("display", c.c_void_p),
                ("window", c.c_ulong), ("message_type", c.c_ulong),
                ("format", c.c_int), ("data", c.c_long * 5)]


class Event(c.Union):
    _fields_ = [("client", ClientMessage), ("padding", c.c_long * 24)]


def main():
    x = c.CDLL("libX11.so.6")
    x.XOpenDisplay.argtypes = [c.c_char_p]
    x.XOpenDisplay.restype = c.c_void_p
    x.XDefaultRootWindow.argtypes = [c.c_void_p]
    x.XDefaultRootWindow.restype = c.c_ulong
    x.XInternAtom.argtypes = [c.c_void_p, c.c_char_p, c.c_int]
    x.XInternAtom.restype = c.c_ulong
    x.XQueryTree.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong),
        c.POINTER(c.c_ulong), c.POINTER(c.POINTER(c.c_ulong)), c.POINTER(c.c_uint)]
    x.XGetWindowProperty.argtypes = [c.c_void_p, c.c_ulong, c.c_ulong,
        c.c_long, c.c_long, c.c_int, c.c_ulong, c.POINTER(c.c_ulong),
        c.POINTER(c.c_int), c.POINTER(c.c_ulong), c.POINTER(c.c_ulong),
        c.POINTER(c.POINTER(c.c_ubyte))]
    x.XFree.argtypes = [c.c_void_p]
    x.XFetchName.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_void_p)]
    x.XGetWMProtocols.argtypes = [c.c_void_p, c.c_ulong,
        c.POINTER(c.POINTER(c.c_ulong)), c.POINTER(c.c_int)]
    x.XSendEvent.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_long, c.POINTER(Event)]
    x.XFlush.argtypes = [c.c_void_p]
    x.XCloseDisplay.argtypes = [c.c_void_p]
    display = x.XOpenDisplay(None)
    if not display:
        raise RuntimeError("X11 display unavailable")
    pid_atom = x.XInternAtom(display, b"_NET_WM_PID", False)
    delete_atom = x.XInternAtom(display, b"WM_DELETE_WINDOW", False)

    def find_window(window, pid):
        actual, size, count, remaining = c.c_ulong(), c.c_int(), c.c_ulong(), c.c_ulong()
        data = c.POINTER(c.c_ubyte)()
        status = x.XGetWindowProperty(display, window, pid_atom, 0, 1, False, 0,
            c.byref(actual), c.byref(size), c.byref(count), c.byref(remaining), c.byref(data))
        match = status == 0 and count.value == 1 and size.value == 32 and (
            c.cast(data, c.POINTER(c.c_ulong))[0] == pid)
        if data:
            x.XFree(data)
        if match:
            name = c.c_void_p()
            x.XFetchName(display, window, c.byref(name))
            title = c.string_at(name) if name.value else b""
            if name.value:
                x.XFree(name)
            # GTK also creates an application leader with the same PID and
            # WM_DELETE_WINDOW; it is not the browser's visible window.
            match = title in (b"flutter_servo_example", b"Servo Browser")
        if match:
            protocols, protocol_count = c.POINTER(c.c_ulong)(), c.c_int()
            x.XGetWMProtocols(display, window, c.byref(protocols), c.byref(protocol_count))
            can_close = any(protocols[i] == delete_atom for i in range(protocol_count.value))
            if protocols:
                x.XFree(protocols)
            if can_close:
                return window
        root, parent, children, length = c.c_ulong(), c.c_ulong(), c.POINTER(c.c_ulong)(), c.c_uint()
        if not x.XQueryTree(display, window, c.byref(root), c.byref(parent),
                            c.byref(children), c.byref(length)):
            return None
        ids = [children[i] for i in range(length.value)]
        if children:
            x.XFree(children)
        for child in ids:
            found = find_window(child, pid)
            if found:
                return found
        return None

    env = dict(os.environ, GDK_BACKEND="x11")
    # Temporary output avoids filling a PIPE while the window is running.
    import tempfile
    with tempfile.TemporaryFile(mode="w+") as output:
        process = subprocess.Popen([sys.argv[1]], env=env, stdout=output, stderr=output)
        try:
            deadline = time.monotonic() + 20
            window = None
            while process.poll() is None and time.monotonic() < deadline:
                window = find_window(x.XDefaultRootWindow(display), process.pid)
                if window:
                    break
                time.sleep(0.1)
            if not window:
                raise RuntimeError("No example window appeared")
            time.sleep(float(sys.argv[2]) if len(sys.argv) > 2 else 8)
            name = c.c_void_p()
            x.XFetchName(display, window, c.byref(name))
            print(f"window_close_probe: window={window} title={c.string_at(name) if name.value else b''}", flush=True)
            if name.value:
                x.XFree(name)
            event = Event()
            event.client.type = 33  # ClientMessage
            event.client.display = display
            event.client.window = window
            event.client.message_type = x.XInternAtom(display, b"WM_PROTOCOLS", False)
            event.client.format = 32
            event.client.data[0] = x.XInternAtom(display, b"WM_DELETE_WINDOW", False)
            started = time.monotonic()
            x.XSendEvent(display, window, False, 0, c.byref(event))
            x.XFlush(display)
            try:
                status = process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                subprocess.run(["gdb", "-batch", "-p", str(process.pid),
                    "-ex", "set pagination off", "-ex", "thread apply all bt 8",
                    "-ex", "detach"], stdout=output, stderr=output, timeout=15)
                raise
            print(f"window_close_probe: exit={status} close_ms={(time.monotonic()-started)*1000:.1f}")
            if status != 0:
                raise RuntimeError("Example exited abnormally")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            output.seek(0)
            print(output.read())
            x.XCloseDisplay(display)


if __name__ == "__main__":
    main()
