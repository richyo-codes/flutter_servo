# Linux Builds

The default Linux build uses GTK3 with standard Flutter. The GTK4 build
requires the [Flutter GTK4 fork](https://github.com/richyo-codes/flutter) and
uses a separate `build/linux-gtk4` output directory.

## GTK3

Install Flutter's [Linux desktop prerequisites](https://docs.flutter.dev/platform-integration/linux/setup).
The plugin requires the GBM and libepoxy development packages. To compile
Servo from source, see the native dependency install step in
[Build Servo Native Assets](../.github/workflows/build-native-assets.yml).
You can also use a [precompiled Servo library](native-builds.md).

From the repository root:

```bash
cd packages/flutter_servo/example
flutter run -d linux
flutter build linux --release
```

The release bundle is in `build/linux/x64/release/bundle` under the example.

## GTK4

For a local debug engine build, run from the repository root:

```bash
export FLUTTER_BIN=/path/to/flutter-gtk4/bin/flutter
export LOCAL_ENGINE_SRC=/path/to/flutter-gtk4/engine/src
bash tools/gtk4_build.sh
```

The wrapper uses the fork's `host_debug_unopt` engine. It can find Flutter on
`PATH` and defaults `LOCAL_ENGINE_SRC` to the SDK's `engine/src` directory.
The GTK3 wrappers `tools/gtk3_build.sh` and `tools/gtk3_build_release.sh` are
available for testing a local fork engine.

If the fork is configured with a prebuilt engine, build from the example:

```bash
FLUTTER_LINUX_GTK=gtk4 /path/to/flutter-gtk4/bin/flutter build linux --release --linux-gtk=gtk4
```

See [GitHub Browser Builds](github-actions.md) for the pinned fork and engine,
the installer used by CI, and RPM and DEB packages for both GTK variants.

## GPU Transfer

The experimental `FLUTTER_SERVO_GPU_TEXTURES=1` path uses EGL images, with
linear GBM DMA-BUFs across displays. It reuses same-size GPU storage and uses
native fence FDs where available. The path still performs a GPU copy.
Drivers without fence export use blocking synchronization, and failed exports
fall back to CPU transfer.

Run `bash tools/run_shared_frame_probe.sh` from the repository root to check
same-display and cross-display transfers on your driver.
