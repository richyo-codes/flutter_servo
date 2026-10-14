#!/usr/bin/env python3
"""Test RPM creation and rejection paths with a small synthetic GTK4 bundle."""

import hashlib
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "tools/build_browser_rpm.sh"
VERIFY = ROOT / "tools/verify_gtk4_bundle.sh"


def run(*args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, **kwargs)


class BrowserRpmTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for command in ("gcc", "pkg-config", "rpm", "rpmbuild", "rpm2cpio", "patchelf", "cpio"):
            if not shutil.which(command):
                raise RuntimeError(f"Missing test dependency: {command}")
        cls.temp = tempfile.TemporaryDirectory(prefix="servo-rpm-test-")
        cls.root = Path(cls.temp.name)
        cls.bundle = cls.root / "release bundle"
        (cls.bundle / "lib").mkdir(parents=True)
        (cls.bundle / "data/flutter_assets").mkdir(parents=True)
        (cls.bundle / "data/icudtl.dat").touch()
        flags = shlex.split(subprocess.check_output(
            ["pkg-config", "--cflags", "--libs", "gtk4"], text=True
        ))
        source = '#include <gtk/gtk.h>\nint main(void) { return gtk_get_major_version() != 4; }\n'
        subprocess.run(
            ["gcc", "-x", "c", "-", "-Wl,-rpath,/temporary/build/tree",
             "-o", str(cls.bundle / "flutter_servo_example"), *flags],
            input=source, text=True, check=True,
        )
        for name in ("libapp", "libflutter_linux_gtk4", "libflutter_servo_plugin",
                     "librust_lib_flutter_servo"):
            source = "void fixture(void) {}\n"
            if name == "librust_lib_flutter_servo":
                source = "void flutter_servo_session_new(void) {}\n"
            subprocess.run(
                ["gcc", "-shared", "-fPIC", "-x", "c", "-",
                 f"-Wl,-soname,{name}.so", "-Wl,-rpath,/temporary/build/tree",
                 "-o", str(cls.bundle / f"lib/{name}.so")],
                input=source, text=True, check=True,
            )

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_build_preserves_bundle_and_generates_dependencies(self):
        original = {
            path.relative_to(self.bundle): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in self.bundle.rglob("*") if path.is_file()
        }
        output = self.root / "rpm output"
        result = run("bash", str(BUILD), "--bundle-dir", str(self.bundle),
                     "--out-dir", str(output), "--version", "v0.1.0-3-gabc123")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        rpm = next(output.glob("*.rpm"))
        identity = run("rpm", "-qp", "--qf", "%{NAME} %{VERSION} %{RELEASE}", str(rpm))
        self.assertEqual(identity.stdout, "flutter-servo-browser-gtk4 0.1.0 3.gabc123")
        files = run("rpm", "-qpl", str(rpm)).stdout
        self.assertIn("/usr/lib64/flutter-servo-browser-gtk4/data/flutter_assets", files)
        self.assertIn("/usr/bin/flutter-servo-browser-gtk4", files)
        requires = run("rpm", "-qp", "--requires", str(rpm)).stdout
        self.assertIn("gtk4", requires)
        self.assertIn("libgtk-4.so.1", requires)
        self.assertNotIn("librust_lib_flutter_servo.so", requires)
        provides = run("rpm", "-qp", "--provides", str(rpm)).stdout
        self.assertNotIn("libflutter_linux_gtk4.so", provides)
        checksum = rpm.with_suffix(".rpm.sha256").read_text().split()[0]
        self.assertEqual(checksum, hashlib.sha256(rpm.read_bytes()).hexdigest())
        self.assertEqual(run("bash", str(VERIFY), str(self.bundle)).returncode, 0)
        for relative, digest in original.items():
            self.assertEqual(hashlib.sha256((self.bundle / relative).read_bytes()).hexdigest(), digest)
        extracted = self.root / "extracted"
        extracted.mkdir()
        archive = subprocess.check_output(["rpm2cpio", str(rpm)])
        subprocess.run(["cpio", "-idm", "--quiet"], input=archive, cwd=extracted, check=True)
        installed = extracted / "usr/lib64/flutter-servo-browser-gtk4"
        self.assertEqual(run("patchelf", "--print-rpath", str(installed / "flutter_servo_example")).stdout.strip(), "$ORIGIN/lib")
        self.assertEqual(run("patchelf", "--print-rpath", str(installed / "lib/librust_lib_flutter_servo.so")).stdout.strip(), "$ORIGIN")
        self.assertEqual(run(str(installed / "flutter_servo_example")).returncode, 0)

    def test_missing_option_value(self):
        result = run("bash", str(BUILD), "--bundle-dir")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Missing value", result.stderr)

    def test_rejects_unsafe_version(self):
        result = run("bash", str(BUILD), "--version", "1.0.0\nName: other")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Invalid artifact version", result.stderr)

    def test_requires_aot_and_renderer(self):
        for filename in ("lib/libapp.so", "lib/librust_lib_flutter_servo.so"):
            file = self.bundle / filename
            hidden = file.with_suffix(".hidden")
            file.rename(hidden)
            try:
                result = run("bash", str(VERIFY), str(self.bundle))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("missing", result.stderr)
            finally:
                hidden.rename(file)

    def test_rejects_gtk3_engine(self):
        engine = self.bundle / "lib/libflutter_linux_gtk.so"
        engine.touch()
        try:
            result = run("bash", str(VERIFY), str(self.bundle))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("GTK3", result.stderr)
        finally:
            engine.unlink()


if __name__ == "__main__":
    unittest.main(verbosity=2)
