# Flutter Servo Embedder

Flutter Servo Embedder is a desktop-focused Flutter library for embedding web content
with Servo. It offers an alternative to platform WebViews and Chromium-based
embedding on Linux and Windows. Android and iOS use the system WebView.

Flutter Servo Embedder is an independent, third-party community project.
It is not affiliated with or endorsed by the Servo project.

## Why Servo?

[Servo](https://servo.org/about/) is a Rust web engine designed to be embedded.
Its WebView API lets Flutter host web content without shipping a standalone
browser. Rust's memory-safety guarantees in safe code help prevent classes of
memory bugs, but don't replace sandboxing or security review.

Servo can be a smaller dependency than a Chromium-based embedder. Actual
bundle size depends on the platform and build options, and Servo doesn't
offer the same web compatibility as Chromium. Test the pages your app needs.

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

## Precompiled Servo

Compiling Servo from source is slow. We publish precompiled Linux and Windows
x64 libraries so Flutter apps can skip that Rust build. Downloads are opt-in
via `prebuilt_native_tag`; Flutter still builds the app and its desktop plugin.

The first pub.dev upload hit a restriction on helper files under `hook/`.
The helper has moved out of that directory. Until the upload is confirmed,
use the [Git dependency and matching binary release](docs/native-builds.md#precompiled-libraries).
There is no announced pub.dev release date.

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
