# flutter_servo

Linux-first Flutter package for embedding Servo-backed web content.

## Current Scope

The package currently provides:

- a small `flutter_rust_bridge` API surface backed by `rust/`
- a Linux plugin that exposes a native texture backed by Rust-rendered pixels
- a package-owned example app under `example/`

The Linux surface renders real Servo content with wake-driven native texture
updates. Rust and its Native Assets hook are contained in this package; Servo
v0.6.0 and the public Surfman fix are pinned in `rust/Cargo.toml`/`Cargo.lock`.
No sibling Rust crate or local Servo/Surfman checkout is required.

The browser offers a basic editing context menu, modifier-aware keyboard
selection, repeat events, and Servo's system clipboard support. Full IME
composition and page-specific DOM context menus are not implemented yet.

## Development

Generate Rust bridge bindings from the repository root:

```bash
./tools/rebuild_rust_bridge.sh
```

Run the example app:

```bash
cd example
flutter run -d linux
```

The Linux example defaults to GTK3. To build GTK4 with the local Flutter GTK4
fork, pass `--linux-gtk=gtk4` and set `FLUTTER_LINUX_GTK=gtk4`; its output is
kept in `build/linux-gtk4` so it does not contaminate GTK3 artifacts.
