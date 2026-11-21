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
- Ctrl+Plus, Ctrl+Minus, and Ctrl+0 adjust and reset desktop page zoom.

Desktop embedders can set `FlutterServoSurface.pageZoom` from 0.5 to 3.0.
Servo combines it with the Flutter view's display scale and updates the page
when the window moves between displays. Zoom does not reload the page.

Loading keeps the previous real frame visible. On startup, a simple loading
surface remains until the first native frame arrives, rather than displaying
a synthetic webpage skeleton.

An experimental `FLUTTER_SERVO_GPU_TEXTURES=1` path shares EGL images, using
linear GBM DMA-BUFs across displays, with CPU transfer as fallback. Linux builds
require the GBM development package. Same-size frames reuse EGL/GBM storage;
native fence FDs order producer writes and consumer reads without CPU waits
where supported. Drivers without fence export retain blocking synchronization.
This path still copies on the GPU; it is not zero-copy. Run
`bash tools/run_shared_frame_probe.sh` from the repository root to check
same-display and cross-display transfers on your driver. Software rendering may
not support cross-display export and will fall back to CPU transfer in the app.

## Development

### Precompiled Servo libraries

The **Servo Native Assets** GitHub Actions workflow uploads optimized Linux x64
libraries and SHA-256 checksums when native build inputs change on a branch.
Manual runs build both Linux x64 and Windows x64. Look for the downloads in the
run's **Artifacts** section. A `native-vX.Y.Z` tag builds both and publishes them under
GitHub Releases once the package license and repository's `BROWSER_LICENSE`
release setting are configured.

Use an archive built from the same commit as your `flutter_servo` dependency.
Check `BUILD_INFO.txt` after extraction and verify the archive against its
`.sha256` file before use. Linux builds use GitHub's `ubuntu-latest` runner and
require compatible system libraries. The Windows archive includes the matching ANGLE
DLLs. Flutter still builds the small desktop plugin and application runner.

Set the extracted directory in your application's `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    flutter_servo:
      prebuilt_native_directory: /absolute/path/to/extracted/archive
```

The hook bundles the libraries without running Cargo. Omit the setting for a
source build. Android and iOS continue using the OS WebView.

The native-assets hook defaults to optimized Rust builds, including when Flutter
is in debug mode. For Rust debugging only, the application's pubspec can override
`hooks.user_defines.flutter_servo.rust_build_mode` to `debug`. Remove that override
before measuring performance or packaging a release.

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
