# Flutter Servo Embedder

Flutter Servo Embedder is a desktop-focused Flutter library for embedding web content
with Servo. It offers an alternative to platform WebViews and Chromium-based
embedding on Linux and Windows. Android and iOS use the system WebView.

Flutter Servo Embedder is an independent, third-party community project.
It is not affiliated with or endorsed by the Servo project.

## Embed a Page

Add `packages/flutter_servo` from this repository as a dependency in your
Flutter app. Initialize Servo once after `WidgetsFlutterBinding.ensureInitialized()`,
then mount a surface in your widget tree:

```dart
await FlutterServo.init();
```

```dart
FlutterServoSurface.url(
  content: 'https://example.com',
  fallback: const SizedBox.shrink(),
)
```

See the [embedding package guide](packages/flutter_servo/README.md) for API
usage and [native build setup](docs/native-builds.md) for build options.

## Example Browser

The [example browser](packages/flutter_servo/example) is a standalone Flutter
app that demonstrates navigation, bookmarks, and embedding demos.

![The Flutter Servo example browser rendering CSS Grid, Flexbox, and SVG](docs/screenshots/rendering.png)

Download a browser bundle from **Browser CI** under **Artifacts**. Linux
offers GTK3 and GTK4 packages, and Windows offers an x64 ZIP.
See [CI builds and downloads](docs/github-actions.md).

To run the GTK3 example from source after installing the
[Linux build prerequisites](docs/linux.md):

```bash
cd packages/flutter_servo/example
flutter run -d linux
```

## Guides

- [Linux builds and GTK4 setup](docs/linux.md)
- [Windows builds](docs/windows.md)
- [Native libraries and Rust builds](docs/native-builds.md)
- [Backend selection and mobile testing](docs/backends.md)
- [Browser demos and screen-reader testing](docs/embedding-demos.md)
