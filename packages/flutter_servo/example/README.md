# flutter_servo_example

Example application for the `flutter_servo` package.

Open **Embedding demos** (the flask icon beside bookmarks) for bundled login /
consent, license-reader, documentation, and video diagnostic pages. See the
[demo guide](../../../docs/embedding-demos.md) for test steps and limitations.
The login flow is mock-only; video playback depends on the native media backend.

The Linux runner embeds Servo; Windows support is experimental. Android uses
the system WebView, not Servo. The package also selects WKWebView on iOS, but this
example does not yet include an iOS runner. See
[backend selection](../../../docs/backends.md) for capabilities and limitations.
