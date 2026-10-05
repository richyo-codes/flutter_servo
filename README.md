# Flutter Servo Browser

Linux-first Flutter + Servo embedding experiment.

## Current State

This repository currently contains:

- `packages/flutter_servo/`: reusable Flutter package and Linux plugin
- `packages/flutter_servo/example/`: demo app consuming the package
- `rust/`: shared Rust crate exposed via `flutter_rust_bridge`
- `packages/flutter_servo/hook/build.dart`: Native Assets Rust build hook
- planning docs for the first embedded Servo MVP

The current demo shows a package-owned Linux native texture surface inside the
example app. That native surface is still a demo renderer, but the pixel data
now comes from the Rust library rather than being painted directly in the Linux
plugin.

## Commands

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
cargo build --release --manifest-path rust/Cargo.toml
```

## Layout

```text
packages/flutter_servo/              Reusable package + Linux plugin
packages/flutter_servo/example/      Demo application
packages/flutter_servo/lib/src/rust/ Generated flutter_rust_bridge Dart bindings
packages/flutter_servo/hook/         Native Assets Rust build hook
rust/                               Rust crate
tools/                              Local helper scripts
docs/                               Planning notes
```
