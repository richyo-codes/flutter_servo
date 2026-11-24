import 'package:flutter/foundation.dart';

enum FlutterServoBackend { auto, servo, webview }

/// Controls implemented by the adapter for a particular target platform.
/// These describe API availability, not enforcement by an installed binary,
/// an OS permission grant, or an isolation guarantee.
enum FlutterServoHostControl {
  navigationPolicy,
  title,
  loadMilestones,
  estimatedLoadPercent,
  blockedPopupNotification,
  clearCookies,
  clearSiteData,
  ephemeralLaunch,
  deniedPermissionNotification,
  geolocationDecision,
  uploadPicker,
  downloadNotification,
}

extension FlutterServoBackendCapabilities on FlutterServoBackend {
  Set<FlutterServoHostControl> hostControls({
    TargetPlatform? platform,
    bool? isWeb,
  }) {
    final target = platform ?? defaultTargetPlatform;
    final backend = resolveFlutterServoBackend(
      this,
      platform: target,
      isWeb: isWeb,
    );
    if (backend == null) return const {};
    return Set.unmodifiable({
      FlutterServoHostControl.navigationPolicy,
      FlutterServoHostControl.title,
      FlutterServoHostControl.loadMilestones,
      FlutterServoHostControl.clearCookies,
      FlutterServoHostControl.deniedPermissionNotification,
      if (backend == FlutterServoBackend.servo) ...{
        FlutterServoHostControl.blockedPopupNotification,
        FlutterServoHostControl.clearSiteData,
        FlutterServoHostControl.ephemeralLaunch,
        FlutterServoHostControl.uploadPicker,
      } else ...{
        FlutterServoHostControl.estimatedLoadPercent,
        if (target == TargetPlatform.android) ...{
          FlutterServoHostControl.geolocationDecision,
          FlutterServoHostControl.uploadPicker,
          FlutterServoHostControl.downloadNotification,
        },
      },
    });
  }

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
  static Future<bool> Function(String)? webview;
}
