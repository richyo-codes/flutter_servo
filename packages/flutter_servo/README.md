# flutter_servo

Linux-first Flutter package for embedding Servo-backed web content.

## Current Scope

The package currently provides:

- a small `flutter_rust_bridge` API surface backed by `rust/`
- a Linux plugin that exposes a native texture backed by Rust-rendered pixels
- a package-owned example app under `example/`

The native Linux surface is still a demo renderer. The next milestone is to
replace that Rust-generated frame source with real Servo frame output.

## Development

Generate Rust bridge bindings from the repository root:

```bash
./tools/rebuild_rust_bridge.sh
```

Run the example app:

```bash
cd packages/flutter_servo/example
flutter run -d linux
```

The Linux example defaults to GTK3. To build GTK4 with the local Flutter GTK4
fork, pass `--linux-gtk=gtk4` and set `FLUTTER_LINUX_GTK=gtk4`; its output is
kept in `build/linux-gtk4` so it does not contaminate GTK3 artifacts.
