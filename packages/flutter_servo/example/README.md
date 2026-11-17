# flutter_servo_example

Example application for the `flutter_servo` package.

Open **Embedding demos** (the flask icon beside bookmarks) for bundled login /
consent, license-reader, documentation, and video diagnostic pages. See the
[demo guide](../../../docs/embedding-demos.md) for test steps and limitations.
The login flow is mock-only; video playback depends on the native media backend.

The Linux runner embeds Servo. The Android runner currently validates the
responsive Flutter browser chrome and displays the fallback surface because the
package does not yet provide an Android Servo plugin.
