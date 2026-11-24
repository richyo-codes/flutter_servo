# Browser backends

The package and example require Flutter 3.47 or newer and Dart 3.13 or newer
(below Dart 4). These declarations match the current resolved WebView platform
implementations. Android's minimum is explicitly API 24; this dependency update
does not raise it. A future iOS runner should use at least iOS 15 for the current
Flutter toolchain; no iOS runner is included or build-verified here.

Desktop remains the Servo target. The default `auto` policy uses Servo on Linux
and Windows, and `webview_flutter` on Android/iOS. macOS and Flutter web currently
report `unsupported-backend`; there is no silent engine substitution there.

```dart
await FlutterServo.init(); // Choose the platform default.
```

To require Servo on Linux or Windows, choose it as the app default:

```dart
await FlutterServo.init(backend: FlutterServoBackend.servo);
```

Or require it for just one surface:

```dart
FlutterServoSurface.url(
  content: 'https://example.com',
  fallback: const SizedBox.shrink(),
  backend: FlutterServoBackend.servo,
  onError: (error) => debugPrint(error.message),
);
```

Use `FlutterServoBackend.webview` to require the system WebView on Android
or iOS. An explicit unsupported choice reports an error and displays the
fallback rather than selecting another engine.
Select your backend before mounting a surface. Use
`resolveFlutterServoBackend(...)` and its capability getters to decide which
settings to display. The static navigation API currently supports one active
surface; a second mobile surface is rejected rather than stealing its controls.

## Common behavior

Both adapters accept HTML and URLs, emit load/navigation/error callbacks, and
support `FlutterServo.goBack()`, `goForward()`, and `reload()`. Changes to
`reloadRevision` reload the supplied content. WebView reports started/complete/
failed; it does not claim a first texture frame from a percentage progress event.
Main-frame resource failures fail the load; subresource failures do not.

## Differences

- Android uses its system WebView; iOS uses WKWebView. Neither is Servo.
- Native WebViews own rendering, touch, keyboard, selection, and native menus.
  `enableContextMenu` controls only Servo's custom menu, not OS WebView menus.
- `enableInputPlumbing: false` blocks Flutter pointer delivery on mobile; it is
  not a security boundary and does not disable scripts or previously focused IME.
- JavaScript is enabled on the mobile adapter, matching the default Servo setup.
- Explicit proxy overrides are Servo-only and throw `UnsupportedError` on mobile.
  Cookie stores, codecs, TLS policies, and network behavior are backend-specific.
- Mobile Native Assets builds skip Rust. No Android NDK Servo build is required.
- Real OAuth should still use the system browser, not either embedded backend.

Servo provides page context menus, modifier-aware keyboard selection, repeat
events, and system clipboard support. Flutter forwards IME preedit and Unicode
commits. Surrounding-text editing, reconversion, and autofill are unimplemented,
and native candidate-window behavior still needs interactive validation.

## Isolation

Desktop Servo runs inside the host process. The Linux Flatpak confines the
whole application, with network, display, and GPU access. Per-page isolation
would require a separate Servo worker and an IPC boundary.

See [Embedding in a kiosk](kiosk.md) for the desktop navigation allowlist,
cookie and site-data scope, and deployment checks.

Run a bundled demo without networking using the installed Flatpak:

```bash
flatpak run --unshare=network ca.richyoung.flutter_servo_browser
```

## Testing

`flutter test` in the package covers platform routing and the mobile adapter with
a fake WebView platform, including navigation, failure, and disposal. Desktop
tests explicitly target Linux. These tests do not validate OS rendering or IME.

Run `./tools/test_android.sh` from the repository root to validate the responsive
browser UI and build an Android debug APK. The output is
`packages/flutter_servo/example/build/app/outputs/flutter-apk/app-debug.apk`.

Run `flutter run -d <android-device>` from `packages/flutter_servo/example` to
test the mobile browser. Test HTTPS, bundled demos, keyboard input, back/forward,
reload, video, background/resume, and closing during navigation. Android requires
Internet permission (already present in the example). HTTPS is the default;
cleartext and TLS policies are not relaxed by this package. An iOS host app must
provide its own runner and meet the deployment requirements of webview_flutter.
