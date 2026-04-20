import 'package:flutter/services.dart';

class FlutterServo {
  static const MethodChannel _channel = MethodChannel('flutter_servo');

  static Future<void> init() async {}

  static void dispose() {}

  static Future<void> setProxySettings({
    String? httpProxyUri,
    String? httpsProxyUri,
    String? noProxy,
  }) {
    return _channel.invokeMethod<void>('setProxySettings', [
      httpProxyUri,
      httpsProxyUri,
      noProxy,
    ]);
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
