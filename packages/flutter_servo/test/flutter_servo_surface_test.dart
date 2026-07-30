import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_servo/flutter_servo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_servo');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('forwards texture-local physical pointer coordinates', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'createTexture' ||
              call.method == 'resizeTexture') {
            return 1;
          }
          return null;
        });

    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 40, top: 30),
            child: SizedBox(
              width: 200,
              height: 100,
              child: FlutterServoSurface.html(
                content: '<p>Input target</p>',
                fallback: const ColoredBox(color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final surface = find.byType(FlutterServoSurface);
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(
      location: tester.getTopLeft(surface) + const Offset(25, 30),
    );
    await pointer.down(tester.getTopLeft(surface) + const Offset(25, 30));
    await tester.pump();

    final buttonCall = calls.lastWhere(
      (call) => call.method == 'notifyMouseButton',
    );
    expect(buttonCall.arguments, [50, 60, 0, true]);

    await pointer.up();
  });

  testWidgets('reloads unchanged content when the revision changes', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'createTexture' ||
              call.method == 'resizeTexture') {
            return 1;
          }
          return null;
        });

    var reloadRevision = 0;
    late StateSetter updateSurface;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            updateSurface = setState;
            return SizedBox(
              width: 200,
              height: 100,
              child: FlutterServoSurface.html(
                content: '<p>Same target</p>',
                reloadRevision: reloadRevision,
                fallback: const ColoredBox(color: Colors.white),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(calls.where((call) => call.method == 'setHtml'), hasLength(1));

    updateSurface(() {
      reloadRevision++;
    });
    await tester.pump();
    await tester.pump();

    expect(calls.where((call) => call.method == 'setHtml'), hasLength(2));
  });

  testWidgets('debounces texture resize to the settled dimensions', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'createTexture' ||
              call.method == 'resizeTexture') {
            return 1;
          }
          return null;
        });

    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);

    var width = 200.0;
    late StateSetter updateSurface;
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: StatefulBuilder(
            builder: (context, setState) {
              updateSurface = setState;
              return SizedBox(
                width: width,
                height: 100,
                child: FlutterServoSurface.html(
                  content: '<p>Resize target</p>',
                  fallback: const ColoredBox(color: Colors.white),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    calls.clear();

    updateSurface(() {
      width = 300;
    });
    await tester.pump(const Duration(milliseconds: 20));
    updateSurface(() {
      width = 400;
    });
    await tester.pump(const Duration(milliseconds: 20));

    expect(calls.where((call) => call.method == 'resizeTexture'), isEmpty);

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    final resizeCalls = calls.where((call) => call.method == 'resizeTexture');
    expect(resizeCalls, hasLength(1));
    expect(resizeCalls.single.arguments, [400, 100]);
  });
}
