# Flutter Servo Embedder

[![pub.dev](https://img.shields.io/pub/v/flutter_servo)](https://pub.dev/packages/flutter_servo)

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

Install [`flutter_servo` from pub.dev](https://pub.dev/packages/flutter_servo):

```bash
flutter pub add flutter_servo
```

Initialize Servo after `WidgetsFlutterBinding.ensureInitialized()`, then
mount a surface in your widget tree:

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

To skip compiling Servo on Linux or Windows x64, add this to your app's
`pubspec.yaml` for `flutter_servo` 0.1.2:

```yaml
hooks:
  user_defines:
    flutter_servo:
      prebuilt_native_tag: native-v0.1.2
```

The first build downloads Servo; later builds reuse it. Omit the setting to
build from source. See the [native build guide](docs/native-builds.md#precompiled-libraries)
for offline setup and system requirements.

## Example Browser

The [example browser](packages/flutter_servo/example) is a standalone Flutter
app that demonstrates navigation, bookmarks, and embedding demos.

![The Flutter Servo example browser displaying a Space Weather bulletin with a geomagnetic activity chart, aurora illustration, and magnetometer log](docs/screenshots/rendering.png)

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
