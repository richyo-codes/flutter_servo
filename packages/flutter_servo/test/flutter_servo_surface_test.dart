import 'dart:async';
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
    await tester.pump(const Duration(milliseconds: 40));

    expect(calls.where((call) => call.method == 'setHtml'), hasLength(2));
    expect(calls.where((call) => call.method == 'refreshTexture'), isNotEmpty);
  });

  testWidgets('retries refresh when the first native frame is unavailable', (
    tester,
  ) async {
    var refreshAttempts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'createTexture' ||
              call.method == 'resizeTexture') {
            return 1;
          }
          if (call.method == 'refreshTexture') {
            refreshAttempts++;
            if (refreshAttempts == 1) {
              throw PlatformException(
                code: 'render-failed',
                message: 'Frame is not ready yet.',
              );
            }
          }
          return null;
        });

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 200,
          height: 100,
          child: FlutterServoSurface.html(
            content: '<p>Delayed frame</p>',
            fallback: const ColoredBox(color: Colors.white),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 120));

    expect(refreshAttempts, greaterThanOrEqualTo(2));
  });

  testWidgets('does not request refreshes for pointer input', (tester) async {
    final firstRefresh = Completer<void>();
    var refreshAttempts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'createTexture' ||
              call.method == 'resizeTexture') {
            return 1;
          }
          if (call.method == 'refreshTexture') {
            refreshAttempts++;
            if (refreshAttempts == 1) {
              await firstRefresh.future;
            }
          }
          return null;
        });

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 200,
          height: 100,
          child: FlutterServoSurface.html(
            content: '<p>Coalesced frame</p>',
            fallback: const ColoredBox(color: Colors.white),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(refreshAttempts, 1);

    final surface = find.byType(FlutterServoSurface);
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: tester.getCenter(surface));
    await pointer.moveTo(tester.getCenter(surface) + const Offset(10, 0));
    await tester.pump(const Duration(milliseconds: 40));
    expect(refreshAttempts, 1);

    firstRefresh.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(refreshAttempts, 1);
  });

  testWidgets('reports native load progress and legacy loading state', (
    tester,
  ) async {
    final progress = <FlutterServoLoadProgress>[];
    final loading = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'createTexture' ||
              call.method == 'resizeTexture') {
            return 1;
          }
          return null;
        });

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 200,
          height: 100,
          child: FlutterServoSurface.html(
            content: '<p>Loading target</p>',
            fallback: const ColoredBox(color: Colors.white),
            onLoadProgressChanged: progress.add,
            onLoadStateChanged: loading.add,
          ),
        ),
      ),
    );
    await tester.pump();

    Future<void> sendLoadProgress(Object value) async {
      final reply = Completer<void>();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('loadStateChanged', value),
            ),
            (_) => reply.complete(),
          );
      await reply.future;
    }

    await sendLoadProgress(0);
    await sendLoadProgress(1);
    await sendLoadProgress(2);

    expect(progress, FlutterServoLoadProgress.values);
    expect(loading, [true, true, false]);
  });

  testWidgets('does not steal focus on reload or pointer hover', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'createTexture' ||
              call.method == 'resizeTexture') {
            return 1;
          }
          return null;
        });

    final addressFocusNode = FocusNode();
    addTearDown(addressFocusNode.dispose);
    var reloadRevision = 0;
    late StateSetter updateSurface;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              updateSurface = setState;
              return Column(
                children: [
                  SizedBox(
                    width: 300,
                    child: TextField(focusNode: addressFocusNode),
                  ),
                  SizedBox(
                    width: 200,
                    height: 100,
                    child: FlutterServoSurface.html(
                      content: '<p>Focus target</p>',
                      reloadRevision: reloadRevision,
                      fallback: const ColoredBox(color: Colors.white),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    addressFocusNode.requestFocus();
    await tester.pump();
    updateSurface(() => reloadRevision++);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(
      location: tester.getCenter(find.byType(FlutterServoSurface)),
    );
    await tester.pump();

    expect(addressFocusNode.hasFocus, isTrue);
  });

  testWidgets('leaves animated frame pumping to the native renderer', (
    tester,
  ) async {
    var refreshAttempts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'createTexture' ||
              call.method == 'resizeTexture') {
            return 1;
          }
          if (call.method == 'refreshTexture') {
            refreshAttempts++;
            return true;
          }
          return null;
        });

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 200,
          height: 100,
          child: FlutterServoSurface.html(
            content: '<p>Animated frame</p>',
            fallback: const ColoredBox(color: Colors.white),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 40));

    expect(refreshAttempts, 1);
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
