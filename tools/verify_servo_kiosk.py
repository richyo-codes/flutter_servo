"""Verify an installed Linux Servo library's launch configuration before loading a URL."""

import argparse
import ctypes
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library", type=Path)
    parser.add_argument("--origin", action="append", default=[],
                        help="Expected HTTPS origin; repeat for multiple. Omit for deny-all.")
    args = parser.parse_args()
    lib = ctypes.CDLL(str(args.library.resolve()))
    new = lib.flutter_servo_session_new
    new.argtypes = [ctypes.c_char_p] * 3
    new.restype = ctypes.c_void_p
    verify = lib.flutter_servo_session_control_response
    verify.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    verify.restype = ctypes.c_bool
    free = lib.flutter_servo_session_free
    free.argtypes = [ctypes.c_void_p]
    free.restype = None
    session = new(None, None, None)
    if not session:
        raise SystemExit("Kiosk verification failed: native session unavailable")
    try:
        query = {"type": "verifyKioskConfiguration", "origins": args.origin}
        if not verify(session, json.dumps(query).encode()):
            raise SystemExit("Kiosk verification failed: unsupported library or configuration mismatch")
        print("Native session has temporary storage and exactly the expected origin allowlist")
    finally:
        free(session)


if __name__ == "__main__":
    main()
