# flutter_servo

A desktop-focused Flutter package for embedding Servo-backed web content.
It provides an alternative to platform WebViews and Chromium-based embedding
on Linux and Windows. Android and iOS use the system WebView.

This is an independent, third-party community package. It is not affiliated
with or endorsed by the Servo project.

## Why Servo?

[Servo](https://servo.org/about/) is a Rust web engine built for embedding.
It offers a potentially smaller alternative to bundling Chromium, and safe
Rust helps prevent classes of memory bugs. Bundle sizes vary by build, and
Servo isn't a drop-in replacement for Chromium's web compatibility.

## Embed a Page

Initialize the package once before mounting a surface:

```dart
await FlutterServo.init();
```

Use a URL or supply HTML with `FlutterServoSurface.html`:

```dart
FlutterServoSurface.url(
  content: 'https://example.com',
  fallback: const SizedBox.shrink(),
)
```

Desktop surfaces support navigation, page zoom, monitor DPI, keyboard and
pointer input, and Servo context menus. Pass `enableContextMenu: true` from a
Material host to show page menus. Set `pageZoom` from 0.5 to 3.0 for page
scaling without reloading. See [backend capabilities](../../docs/backends.md)
for platform differences.

## Precompiled Servo

Skip the slow Servo source build on Linux and Windows x64 by setting
`hooks.user_defines.flutter_servo.prebuilt_native_tag` in your app's
`pubspec.yaml`. Use `native-v0.1.2` with package version `0.1.2`. For offline
builds, use `prebuilt_native_directory` with an already extracted archive.
Omit both settings to build Servo from source.

The initial pub.dev upload was rejected because its download helper was
under `hook/`. The helper has been moved; until publication is confirmed,
use a Git dependency. See the
[native build guide](https://github.com/richyo-codes/flutter_servo/blob/main/docs/native-builds.md#precompiled-libraries)
for the matching Git revision, download settings, and prerequisites.

## Build and Test

- [Linux GTK3 and GTK4 builds](../../docs/linux.md)
- [Windows setup](../../docs/windows.md)
- [Precompiled libraries, profiling, and bridge generation](../../docs/native-builds.md)
- [Example browser and screen-reader tests](../../docs/embedding-demos.md)
- [CI artifacts and Linux packages](../../docs/github-actions.md)
