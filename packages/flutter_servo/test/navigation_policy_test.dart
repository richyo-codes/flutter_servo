import 'package:flutter_servo/flutter_servo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('handoff notifies the host but never authorizes the browser', () {
    final target = Uri.parse('https://support.example/help');
    final seen = <(Uri, bool?)>[];
    final policy = FlutterServoNavigationPolicy(
      decide: (_, _) => FlutterServoNavigationDecision.handOff,
      onHandOff: (uri, main) => seen.add((uri, main)),
    );
    expect(policy.allows(target, null), isFalse);
    expect(seen, [(target, null)]);
    expect(policy.allows(Uri.parse('/relative'), true), isFalse);
    expect(seen, hasLength(1));
    expect(
      FlutterServoNavigationPolicy(
        decide: (_, _) => FlutterServoNavigationDecision.handOff,
        onHandOff: (_, _) => throw StateError('host unavailable'),
      ).allows(target, true),
      isFalse,
    );
  });
}
