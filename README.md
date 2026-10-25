# Flutter Servo Browser

Linux-first Flutter + Servo embedding experiment.

## Current State

This repository currently contains:

- `packages/flutter_servo/`: reusable Flutter package and Linux plugin
- `packages/flutter_servo/example/`: demo app consuming the package
- `packages/flutter_servo/rust/`: package-owned Rust crate
- `packages/flutter_servo/hook/build.dart`: Native Assets Rust build hook
- planning docs for the first embedded Servo MVP

The example embeds real Servo content in a package-owned Linux native texture.
Frame updates are wake-driven; the GTK thread does not wait for scene readiness.

## Dependencies

Servo and its allocator are pinned to the public `v0.7.0` release. Surfman
0.14.0 uses the public [Surfman fork](https://github.com/richyo-codes/surfman)
at commit `0e2cd47b6390eefb6d0ecbb927a34bc03fc0f2cb` from
`fix/no-runtime-env-mutation-v4`. Cargo no longer requires local Servo or
Surfman checkouts; the committed lockfile records the resolved revisions.

The Surfman patch avoids changing process-wide Mesa environment variables
after Flutter starts threads. It does not force software or PRIME adapter
selection. If needed, set `LIBGL_ALWAYS_SOFTWARE` or `DRI_PRIME` before starting
the app. This remains a downstream workaround pending an upstream solution
that preserves adapter selection without runtime environment mutation. The
problem is tracked in [Surfman #402](https://github.com/servo/surfman/issues/402).

## Commands

GitHub Actions builds a GTK4 release browser RPM on pushes, pull requests, and
manual runs. Download it from **Browser CI** under **Artifacts**; tagged release
publishing and local RPM commands are described in
[GitHub Browser Builds](docs/github-actions.md).

Generate bridge bindings:

```bash
./tools/rebuild_rust_bridge.sh
```

Run the example app:

```bash
cd packages/flutter_servo/example
flutter run -d linux
```

Validate the responsive browser UI and build the Android debug APK:

```bash
./tools/test_android.sh
```

The Android runner currently exercises the Flutter browser chrome and fallback
surface only. Servo rendering remains Linux-only until an Android native plugin
is implemented. The APK is written to
`packages/flutter_servo/example/build/app/outputs/flutter-apk/app-debug.apk`.

Build the GTK4 variant with the local Flutter GTK4 fork:

```bash
cd packages/flutter_servo/example
FLUTTER_LINUX_GTK=gtk4 /path/to/flutter-gtk4/bin/flutter build linux --debug \
  --linux-gtk=gtk4 \
  --local-engine=host_debug_unopt \
  --local-engine-host=host_debug_unopt \
  --local-engine-src-path=/path/to/flutter-gtk4/engine/src
```

GTK3 is the default and remains the portable CPU-upload path. GTK4 creates an
isolated `build/linux-gtk4` directory and is the target for EGLImage interop.

Build the Rust library directly:

```bash
cargo build --release --manifest-path packages/flutter_servo/rust/Cargo.toml --features servo-engine
```

## Layout

```text
packages/flutter_servo/              Reusable package + Linux plugin
packages/flutter_servo/example/      Demo application
packages/flutter_servo/lib/src/rust/ Generated flutter_rust_bridge Dart bindings
packages/flutter_servo/hook/         Native Assets Rust build hook
packages/flutter_servo/rust/         Rust crate
tools/                              Local helper scripts
docs/                               Planning notes
```
