# flutter_servo

A desktop-focused Flutter package for embedding Servo-backed web content.
It provides an alternative to platform WebViews and Chromium-based embedding
on Linux and Windows. Android and iOS use the system WebView.

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

## Build and Test

- [Linux GTK3 and GTK4 builds](../../docs/linux.md)
- [Windows setup](../../docs/windows.md)
- [Precompiled libraries, profiling, and bridge generation](../../docs/native-builds.md)
- [Example browser and screen-reader tests](../../docs/embedding-demos.md)
- [CI artifacts and Linux packages](../../docs/github-actions.md)
