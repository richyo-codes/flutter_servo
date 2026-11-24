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

Install the package with `flutter pub add flutter_servo`, then initialize it
once before mounting a surface:

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

Pass a `FlutterServoController` to a surface to load URLs or HTML, navigate
back and forward, reload, or set desktop zoom. Use one controller per
surface. The desktop native plugin currently supports one mounted surface
per engine; controlled mobile WebViews can be mounted independently.

Building a kiosk? See [navigation restrictions and visitor data](https://github.com/richyo-codes/flutter_servo/blob/main/docs/kiosk.md)
before enabling remote content. These controls require a matching native build
and are not a substitute for OS isolation or outbound network policy.

## Precompiled Servo

To skip compiling Servo on Linux or Windows x64, add this to your app's
`pubspec.yaml` for `flutter_servo` 0.1.2:

```yaml
hooks:
  user_defines:
    flutter_servo:
      prebuilt_native_tag: native-v0.1.2
```

The first build downloads Servo; later builds reuse it. Omit the setting to
build from source. See the
[native build guide](https://github.com/richyo-codes/flutter_servo/blob/main/docs/native-builds.md#precompiled-libraries)
for offline setup and system requirements.

## Build and Test

- [Linux GTK3 and GTK4 builds](../../docs/linux.md)
- [Windows setup](../../docs/windows.md)
- [Precompiled libraries, profiling, and bridge generation](../../docs/native-builds.md)
- [Example browser and screen-reader tests](../../docs/embedding-demos.md)
- [CI artifacts and Linux packages](../../docs/github-actions.md)
