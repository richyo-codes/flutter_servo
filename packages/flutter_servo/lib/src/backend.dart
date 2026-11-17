import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

enum FlutterServoBackend { auto, servo, webview }

extension FlutterServoBackendCapabilities on FlutterServoBackend {
  /// Inspect a resolved backend, not [FlutterServoBackend.auto].
  bool get supportsProxyOverrides => this == FlutterServoBackend.servo;
  bool get supportsCustomContextMenus => this == FlutterServoBackend.servo;
  bool get usesNativeWebView => this == FlutterServoBackend.webview;
}

/// Resolve without silently replacing an explicitly requested engine.
FlutterServoBackend? resolveFlutterServoBackend(
  FlutterServoBackend requested, {
  TargetPlatform? platform,
  bool? isWeb,
}) {
  if (isWeb ?? kIsWeb) return null;
  final target = platform ?? defaultTargetPlatform;
  final mobile =
      target == TargetPlatform.android || target == TargetPlatform.iOS;
  final desktop =
      target == TargetPlatform.linux || target == TargetPlatform.windows;
  if (requested == FlutterServoBackend.auto) {
    return mobile
        ? FlutterServoBackend.webview
        : desktop
        ? FlutterServoBackend.servo
        : null;
  }
  return (requested == FlutterServoBackend.webview && mobile) ||
          (requested == FlutterServoBackend.servo && desktop)
      ? requested
      : null;
}

/// Internal routing for the existing single-surface static navigation API.
class BackendSession {
  static FlutterServoBackend preference = FlutterServoBackend.auto;
  static WebViewController? webview;
}
