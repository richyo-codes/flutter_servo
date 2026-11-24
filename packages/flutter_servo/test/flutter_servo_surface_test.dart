import 'dart:async';
import 'dart:convert';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_servo/flutter_servo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_servo');

  Future<void> sendControl(Map<String, Object?> event) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('embedderControl', jsonEncode(event)),
          ),
          (_) {},
        );
  }

  Future<void> sendProgress(int value) async {
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

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testServoWidgets('controller routes commands only to its desktop surface', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return switch (call.method) {
        'createTexture' || 'resizeTexture' => 1,
        'goBack' || 'goForward' || 'reload' => true,
        _ => null,
      };
    });
    final controller = FlutterServoController();
    final second = FlutterServoController();
    final showFirst = ValueNotifier(true);
    addTearDown(showFirst.dispose);
    final errors = <PlatformException>[];
    expect(() => controller.loadHtml('detached'), throwsStateError);
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            Expanded(
              child: ValueListenableBuilder<bool>(
                valueListenable: showFirst,
                builder: (_, visible, child) =>
                    visible ? child! : const SizedBox(),
                child: FlutterServoSurface.html(
                  controller: controller,
                  content: '<h1>Initial</h1>',
                  fallback: const SizedBox(),
                ),
              ),
            ),
            Expanded(
              child: FlutterServoSurface.html(
                controller: second,
                content: '<h1>Second</h1>',
                fallback: const SizedBox(),
                onError: errors.add,
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(controller.isAttached, isTrue);
    expect(errors.single.code, 'servo-session-in-use');
    expect(await second.goBack(), isFalse);
    expect(() => second.loadHtml('wrong view'), throwsStateError);
    expect(calls.where((call) => call.method == 'createTexture'), hasLength(1));
    expect(await controller.goBack(), isTrue);
    expect(await controller.goForward(), isTrue);
    expect(await controller.reload(), isTrue);
    controller.loadUrl(Uri.parse('https://example.org/controller'));
    controller.setZoom(1.5);
    await tester.pump();
    await tester.pump();
    expect(
      calls.lastWhere((call) => call.method == 'setUrl').arguments.first,
      'https://example.org/controller',
    );
    expect(
      calls.lastWhere((call) => call.method == 'resizeTexture').arguments.last,
      1.5,
    );
    controller.loadHtml('<h1>Controller HTML</h1>');
    await tester.pump();
    await tester.pump();
    expect(
      calls.lastWhere((call) => call.method == 'setHtml').arguments.first,
      '<h1>Controller HTML</h1>',
    );
    showFirst.value = false;
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(controller.isAttached, isFalse);
    expect(await second.reload(), isTrue);
    expect(calls.where((call) => call.method == 'createTexture'), hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(controller.isAttached, isFalse);
    expect(second.isAttached, isFalse);
  });

  testServoWidgets(
    'keeps loading UI until a real frame, preserves it during navigation',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'createTexture' ||
                call.method == 'resizeTexture') {
              return 1;
            }
            return true;
          });
      await tester.pumpWidget(
        const MaterialApp(
          home: FlutterServoSurface.html(
            content: '<p>Page</p>',
            fallback: Text('Opening page'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Opening page'), findsOneWidget);
      expect(find.byType(Texture), findsOneWidget);
      await sendProgress(2);
      await tester.pump();
      expect(find.text('Opening page'), findsOneWidget);
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('frameAvailable'),
            ),
            (_) {},
          );
      await tester.pump();
      expect(find.text('Opening page'), findsNothing);
      await sendProgress(0);
      await tester.pump();
      expect(find.text('Opening page'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testServoWidgets('accepts retained frame notification while reattaching', (
    tester,
  ) async {
    var creations = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'createTexture') {
            creations++;
            // Native reattachment can replay readiness before create returns.
            if (creations > 1) {
              await TestDefaultBinaryMessengerBinding
                  .instance
                  .defaultBinaryMessenger
                  .handlePlatformMessage(
                    channel.name,
                    const StandardMethodCodec().encodeMethodCall(
                      const MethodCall('frameAvailable'),
                    ),
                    (_) {},
                  );
            }
            return 1;
          }
          return true;
        });
    const surface = MaterialApp(
      home: FlutterServoSurface.html(
        content: '',
        fallback: Text('Opening page'),
      ),
    );
    await tester.pumpWidget(surface);
    await tester.pump();
    expect(find.text('Opening page'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(surface);
    await tester.pump();
    expect(creations, 2);
    expect(find.byType(Texture), findsOneWidget);
    expect(find.text('Opening page'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final crash in [true, false]) {
    testServoWidgets(
      crash
          ? 'reports native crashes once until retry'
          : 'times out stalled native loads',
      (tester) async {
        final errors = <PlatformException>[];
        final progress = <FlutterServoLoadProgress>[];
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              if (call.method == 'createTexture' ||
                  call.method == 'resizeTexture') {
                return 1;
              }
              return true;
            });
        var revision = 0;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return FlutterServoSurface.html(
                  content: '<p>Recovery target</p>',
                  reloadRevision: revision,
                  loadTimeout: const Duration(milliseconds: 100),
                  onError: errors.add,
                  onLoadProgressChanged: progress.add,
                  fallback: const SizedBox(),
                );
              },
            ),
          ),
        );
        await tester.pump();
        await sendProgress(0);
        if (crash) {
          await sendProgress(3);
          await sendProgress(3);
        }
        await tester.pump(const Duration(seconds: 1));
        expect(
          errors.single.code,
          crash ? 'servo-crashed' : 'servo-load-timeout',
        );
        expect(progress.last, FlutterServoLoadProgress.failed);
        await sendProgress(2);
        expect(progress.last, FlutterServoLoadProgress.failed);
        final refreshes = calls
            .where((call) => call.method == 'refreshTexture')
            .length;
        await tester.pump(const Duration(seconds: 3));
        expect(
          calls.where((call) => call.method == 'refreshTexture').length,
          refreshes,
        );
        update(() => revision++);
        await tester.pump();
        await tester.pump();
        if (!crash) {
          // A stalled retry may not produce another native "started" callback.
          await tester.pump(const Duration(seconds: 1));
          expect(errors, hasLength(2));
          expect(progress.last, FlutterServoLoadProgress.failed);
          update(() => revision++);
          await tester.pump();
          await tester.pump();
        }
        await sendProgress(0);
        await sendProgress(2);
        expect(progress.last, FlutterServoLoadProgress.complete);
        expect(errors, hasLength(crash ? 1 : 2));
        expect(
          calls.where((call) => call.method == 'setHtml'),
          hasLength(crash ? 2 : 3),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testServoWidgets('reports failed loads once and allows explicit reload', (
    tester,
  ) async {
    final errors = <PlatformException>[];
    final calls = <MethodCall>[];
    var rejectLoad = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'createTexture' ||
              call.method == 'resizeTexture') {
            return 1;
          }
          if (call.method == 'setHtml' && rejectLoad) {
            throw PlatformException(code: 'session-update-failed');
          }
          return null;
        });
    var revision = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return FlutterServoSurface.html(
              content: '<p>Retry target</p>',
              reloadRevision: revision,
              onError: errors.add,
              fallback: const ColoredBox(color: Colors.white),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(errors.single.code, 'session-update-failed');
    expect(calls.where((call) => call.method == 'setHtml'), hasLength(1));
    expect(calls.where((call) => call.method == 'refreshTexture'), isEmpty);
    expect(tester.takeException(), isNull);

    rejectLoad = false;
    update(() => revision++);
    await tester.pump();
    await tester.pump();
    expect(calls.where((call) => call.method == 'setHtml'), hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testServoWidgets('serializes creation and loads the latest pending content', (
    tester,
  ) async {
    final creation = Completer<int>();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'createTexture') return creation.future;
          if (call.method == 'resizeTexture') return 1;
          return null;
        });
    var content = '<p>Initial</p>';
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return FlutterServoSurface.html(
              content: content,
              fallback: const ColoredBox(color: Colors.white),
            );
          },
        ),
      ),
    );
    update(() => content = '<p>Latest</p>');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(calls.where((call) => call.method == 'createTexture'), hasLength(1));

    creation.complete(1);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final loads = calls.where((call) => call.method == 'setHtml');
    expect(loads, hasLength(1));
    expect(loads.single.arguments, ['<p>Latest</p>']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testServoWidgets('forwards texture-local physical pointer coordinates', (
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

  testServoWidgets(
    'applies page cursors and separates Ctrl+wheel from scrolling',
    (tester) async {
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
      final zoomSteps = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: FlutterServoSurface.html(
            content: '<p>Scroll target</p>',
            fallback: const ColoredBox(color: Colors.white),
            onWheelZoom: zoomSteps.add,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final origin = tester.getTopLeft(find.byType(FlutterServoSurface));
      for (final (name, cursor) in [
        ('Pointer', SystemMouseCursors.click),
        ('Text', SystemMouseCursors.text),
        ('Default', SystemMouseCursors.basic),
      ]) {
        await sendControl({'type': 'cursor', 'cursor': name});
        await tester.pump();
        expect(
          tester
              .widgetList<MouseRegion>(find.byType(MouseRegion))
              .map((region) => region.cursor),
          contains(cursor),
        );
      }
      for (final delta in [const Offset(12, 30), const Offset(-12, -30)]) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: origin + const Offset(25, 30),
            scrollDelta: delta,
          ),
        );
        await tester.pump();
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      try {
        for (final dy in [-30.0, 30.0]) {
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: origin + const Offset(25, 30),
              scrollDelta: Offset(0, dy),
            ),
          );
        }
      } finally {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      }
      await tester.pump();
      expect(zoomSteps, [1, -1]);
      final wheels = calls.where((call) => call.method == 'notifyMouseWheel');
      expect(wheels.map((call) => call.arguments).toList(), [
        [50, 60, -24, -60],
        [50, 60, 24, 60],
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testServoWidgets('forwards repeats and resolves page-specific menus', (
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
          return true;
        });
    await tester.pumpWidget(
      const MaterialApp(
        home: FlutterServoSurface.html(
          content: '<input>',
          enableContextMenu: true,
          fallback: SizedBox(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(FlutterServoSurface));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA, character: 'a');
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyA, character: 'a');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(
      calls
          .where((call) => call.method == 'notifyKeyEvent')
          .map((call) => call.arguments)
          .toList(),
      [
        ['A', 'a', true],
        ['A', 'a', true],
        ['A', '', false],
      ],
    );
    calls.clear();
    final pointer = await tester.startGesture(
      tester.getCenter(find.byType(FlutterServoSurface)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await pointer.up();
    await sendControl({
      'type': 'contextMenu',
      'id': 7,
      'x': 80,
      'y': 80,
      'items': [
        {'index': 0, 'label': 'Copy link address', 'enabled': true},
        {'index': 1, 'label': 'Open link in new window', 'enabled': false},
      ],
    });
    await tester.pumpAndSettle();
    expect(find.text('Copy link address'), findsOneWidget);
    expect(
      tester
          .widget<PopupMenuItem<int>>(
            find.ancestor(
              of: find.text('Open link in new window'),
              matching: find.byType(PopupMenuItem<int>),
            ),
          )
          .enabled,
      isFalse,
    );
    await tester.tap(find.text('Copy link address'));
    await tester.pumpAndSettle();
    expect(
      calls
          .where((call) => call.method == 'respondToControl')
          .map((call) => jsonDecode(call.arguments as String))
          .toList(),
      [
        {'type': 'contextMenu', 'id': 7, 'index': 0},
      ],
    );
    expect(
      calls.where((call) => call.method == 'notifyMouseButton'),
      hasLength(2),
    );

    await sendControl({
      'type': 'contextMenu',
      'id': 8,
      'x': 80,
      'y': 80,
      'items': [
        {'index': 0, 'label': 'Copy', 'enabled': true},
      ],
    });
    await tester.pumpAndSettle();
    await sendControl({'type': 'hideContextMenu', 'id': 7});
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    await sendControl({'type': 'hideContextMenu', 'id': 8});
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testServoWidgets('reloads unchanged content when the revision changes', (
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

  testServoWidgets(
    'retries refresh when the first native frame is unavailable',
    (tester) async {
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
    },
  );

  testServoWidgets('does not request refreshes for pointer input', (
    tester,
  ) async {
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

  testServoWidgets('reports native load progress and legacy loading state', (
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

    expect(progress, [
      FlutterServoLoadProgress.started,
      FlutterServoLoadProgress.firstFrame,
      FlutterServoLoadProgress.complete,
    ]);
    expect(loading, [true, true, false]);
  });

  testServoWidgets('does not steal focus on reload or pointer hover', (
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

  testServoWidgets('leaves animated frame pumping to the native renderer', (
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

  testServoWidgets('exposes page semantics and routes a screen reader action', (
    tester,
  ) async {
    final responses = <Object?>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'createTexture') return 1;
      if (call.method == 'respondToControl') {
        responses.add(jsonDecode(call.arguments as String));
        return true;
      }
      return null;
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: FlutterServoSurface.html(
          content: '<button>Continue</button>',
          fallback: SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      responses,
      contains(equals({'type': 'accessibilityEnabled', 'enabled': true})),
    );
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('frameAvailable'),
      ),
      (_) {},
    );
    await sendControl({
      'type': 'accessibilityTree',
      'nodes': [
        {
          'id': 'tree:1',
          'role': 'Heading',
          'label': 'Form title',
          'rect': [10, 10, 110, 40],
        },
        {
          'id': 'tree:2',
          'role': 'Button',
          'label': 'Continue',
          'rect': [10, 50, 110, 80],
          'clickable': true,
        },
      ],
    });
    await tester.pump();
    expect(find.bySemanticsLabel('Form title'), findsOneWidget);
    final button = tester.getSemantics(find.bySemanticsLabel('Continue'));
    expect(button.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    button.owner!.performAction(button.id, SemanticsAction.tap);
    await tester.pump();
    expect(responses.last, {
      'type': 'accessibilityAction',
      'id': 'tree:2',
      'action': 'Click',
    });

    await sendControl({'type': 'accessibilityTree', 'nodes': []});
    await tester.pump();
    expect(find.bySemanticsLabel('Continue'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(responses.last, {'type': 'accessibilityEnabled', 'enabled': false});
  });

  testServoWidgets('coalesces live resize and forwards DPI and page zoom', (
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
    var pageZoom = 1.0;
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
                  pageZoom: pageZoom,
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

    await tester.pump(const Duration(milliseconds: 21));

    updateSurface(() => width = 500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    tester.view.devicePixelRatio = 1.5;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    updateSurface(() => pageZoom = 1.25);
    await tester.pumpAndSettle();
    expect(
      calls
          .where((call) => call.method == 'resizeTexture')
          .map((call) => call.arguments),
      [
        [400, 100, 1.0, 1.0],
        [500, 100, 1.0, 1.0],
        [750, 150, 1.5, 1.0],
        [750, 150, 1.5, 1.25],
      ],
    );
  });
}

void testServoWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(
    description,
    callback,
    variant: TargetPlatformVariant({TargetPlatform.linux}),
  );
}
