/// Where a requested URL should go. No decision starts an OS application.
enum FlutterServoNavigationDecision { navigate, block, handOff }

/// Pass [allows] to a surface's `allowNavigation` callback. The classifier is
/// called for each request the backend reports, including subframe requests.
/// Unknown frame scope is null; it does not imply a user gesture.
class FlutterServoNavigationPolicy {
  const FlutterServoNavigationPolicy({required this.decide, this.onHandOff});

  final FlutterServoNavigationDecision Function(Uri url, bool? isMainFrame)
  decide;

  /// Use this to offer a host-controlled action, not to launch untrusted URLs
  /// automatically. An absent handler leaves a handoff request blocked.
  final void Function(Uri url, bool? isMainFrame)? onHandOff;

  bool allows(Uri url, bool? isMainFrame) {
    if (!url.hasScheme) return false;
    try {
      switch (decide(url, isMainFrame)) {
        case FlutterServoNavigationDecision.navigate:
          return true;
        case FlutterServoNavigationDecision.block:
          return false;
        case FlutterServoNavigationDecision.handOff:
          onHandOff?.call(url, isMainFrame);
          return false;
      }
    } catch (_) {
      return false;
    }
  }
}
