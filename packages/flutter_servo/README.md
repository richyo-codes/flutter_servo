# flutter_servo

Linux-first Flutter package for embedding Servo-backed web content.

Windows x64 support is experimental. The Windows plugin reuses the Dart input
and browser-control APIs, and sends Servo frames through Flutter pixel-buffer
textures. Its build hook bundles the ANGLE DLLs needed at runtime. See the
repository's [Windows guide](../../docs/windows.md) for setup and testing.

## Current Scope

The package currently provides:

- a small `flutter_rust_bridge` API surface backed by `rust/`
- a Linux plugin that exposes a native texture backed by Rust-rendered pixels
- a package-owned example app under `example/`

The Linux surface renders real Servo content with wake-driven native texture
updates. Rust and its Native Assets hook are contained in this package; Servo
v0.8.0 with the WindowProxy fix and the public Surfman 0.14 fix are pinned in
`rust/Cargo.toml`/`Cargo.lock`. Servo comes from the public
[Servo fork](https://github.com/richyo-codes/servo); no SSH credentials are required.
No sibling Rust crate or local Servo/Surfman checkout is required. Cargo uses
the Git CLI through the workspace's `.cargo/config.toml`.

The browser offers Servo-provided page context menus, modifier-aware keyboard
selection, repeat events, and Servo's system clipboard support. Flutter text
input forwards IME preedit and Unicode commits; surrounding-text editing,
reconversion, and autofill are not yet supported. Native IME candidate-window
behavior still needs interactive validation.

Browser shortcuts work while the webpage has focus:

- Ctrl+L, Ctrl+K, Alt+D, or F6 focuses and selects the address bar.
- Ctrl+R or F5 reloads the page.
- Alt+Left/Right navigates back/forward.
- Ctrl+D toggles the current page's bookmark.

Loading keeps the previous real frame visible. On startup, a simple loading
surface remains until the first native frame arrives, rather than displaying
a synthetic webpage skeleton.

An experimental `FLUTTER_SERVO_GPU_TEXTURES=1` path shares EGL images, using
linear GBM DMA-BUFs across displays, with CPU transfer as fallback. Linux builds
require the GBM development package. This path still copies on the GPU and uses
blocking synchronization; it is not zero-copy. Standalone GPU probes pass, but
the tested GTK4 application selects llvmpipe and falls back to CPU transfer.

## Development

Generate Rust bridge bindings from the repository root:

```bash
./tools/rebuild_rust_bridge.sh
```

In a standalone package checkout, run `flutter_rust_bridge_codegen generate`
from the package root; the package includes its own generator configuration.

Run the example app:

```bash
cd example
flutter run -d linux
```

The Linux example defaults to GTK3. To build GTK4 with the local Flutter GTK4
fork, pass `--linux-gtk=gtk4` and set `FLUTTER_LINUX_GTK=gtk4`; its output is
kept in `build/linux-gtk4` so it does not contaminate GTK3 artifacts.
