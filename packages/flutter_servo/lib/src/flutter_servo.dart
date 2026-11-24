import 'package:flutter/services.dart';
import 'backend.dart';

class FlutterServo {
  static const MethodChannel _channel = MethodChannel('flutter_servo');

  static Future<void> init({
    FlutterServoBackend backend = FlutterServoBackend.auto,
  }) async {
    BackendSession.preference = backend;
  }

  static void dispose() {}

  static Future<void> setProxySettings({
    String? httpProxyUri,
    String? httpsProxyUri,
    String? noProxy,
  }) {
    if (resolveFlutterServoBackend(BackendSession.preference) !=
        FlutterServoBackend.servo) {
      throw UnsupportedError(
        'Proxy overrides are only supported by the Servo backend.',
      );
    }
    return _channel.invokeMethod<void>('setProxySettings', [
      httpProxyUri,
      httpsProxyUri,
      noProxy,
    ]);
  }

  static Future<bool> goBack() => _navigate('goBack');

  static Future<bool> goForward() => _navigate('goForward');

  static Future<bool> reload() => _navigate('reload');

  static Future<bool> _navigate(String command) async {
    final navigateWebView = BackendSession.webview;
    if (navigateWebView != null) return navigateWebView(command);
    if (resolveFlutterServoBackend(BackendSession.preference) !=
        FlutterServoBackend.servo) {
      return false;
    }
    return await _channel.invokeMethod<bool>(command) ?? false;
  }

  static String greet({required String name}) => 'Hello from Rust, $name.';

  static String mvpInitialUrl() =>
      'data:text/html;charset=utf-8,<html><body><h1>Hello from Servo</h1><p>Rendered inside Flutter.</p></body></html>';

  static String mvpInitialHtml() => '''<html>
  <body>
    <h1>Hello from Servo</h1>
    <p>Rendered inside Flutter.</p>
  </body>
</html>''';
}
