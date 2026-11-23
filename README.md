# Flutter Servo Browser

Desktop-focused browser and Flutter embedding library powered by Servo. It
offers a Servo-based alternative to platform WebViews and Chromium-based
embedding on Linux and Windows. Android and iOS use the system WebView.

## Quick Start

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

- [Embedding package](packages/flutter_servo/README.md)
- [Linux builds and GTK4 setup](docs/linux.md)
- [Windows builds](docs/windows.md)
- [Native libraries and Rust builds](docs/native-builds.md)
- [Backend selection and mobile testing](docs/backends.md)
- [Browser demos and screen-reader testing](docs/embedding-demos.md)
