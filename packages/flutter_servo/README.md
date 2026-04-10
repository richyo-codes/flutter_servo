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
