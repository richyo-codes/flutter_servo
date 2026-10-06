import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_servo_example/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_servo');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final nativeCrash in [true, false]) {
    testWidgets(
      nativeCrash
          ? 'offers retry after a native crash'
          : 'offers retry after a rejected load',
      (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final calls = <MethodCall>[];
        var rejectLoad = !nativeCrash;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              if (call.method == 'createTexture' ||
                  call.method == 'resizeTexture') {
                return 1;
              }
              if (call.method == 'setUrl' && rejectLoad) {
                throw PlatformException(code: 'session-update-failed');
              }
              return true;
            });
        await tester.pumpWidget(const ServoBrowserApp());
        await tester.pump();
        await tester.pump();
        if (nativeCrash) {
          final reply = Completer<void>();
          await TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .handlePlatformMessage(
                channel.name,
                const StandardMethodCodec().encodeMethodCall(
                  const MethodCall('loadStateChanged', 3),
                ),
                (_) => reply.complete(),
              );
          await reply.future;
          await tester.pump();
        }
        expect(find.text('Page could not be rendered'), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        rejectLoad = false;
        await tester.tap(find.text('Try Again'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Page could not be rendered'), findsNothing);
        expect(calls.where((call) => call.method == 'setUrl'), hasLength(2));
        expect(calls.where((call) => call.method == 'reload'), isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('Ctrl+L focuses, replaces, and submits the address', (
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

    await tester.pumpWidget(const ServoBrowserApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    calls.clear();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    final address = find.byType(EditableText);
    expect(address, findsOneWidget);
    expect(tester.widget<EditableText>(address).focusNode.hasFocus, isTrue);

    await tester.enterText(find.byType(TextField), 'example.com');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();

    final navigation = calls.lastWhere((call) => call.method == 'setUrl');
    expect(navigation.arguments, ['https://example.com']);
  });

  testWidgets('Ctrl+R reloads and immediately enters loading state', (
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
          if (call.method == 'reload') {
            return true;
          }
          return null;
        });

    await tester.pumpWidget(const ServoBrowserApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    calls.clear();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(calls.where((call) => call.method == 'reload'), hasLength(1));
    expect(find.text('LOADING'), findsOneWidget);
  });

  for (final size in [const Size(360, 640), const Size(390, 844)]) {
    testWidgets(
      'browser chrome fits ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'createTexture' ||
                  call.method == 'resizeTexture') {
                return 1;
              }
              return null;
            });

        await tester.pumpWidget(const ServoBrowserApp());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));

        expect(tester.takeException(), isNull);
        expect(find.byType(TextField), findsOneWidget);
        expect(find.byKey(const ValueKey('bookmark-toggle')), findsOneWidget);
      },
    );
  }

  testWidgets('bookmarks persist and open from the toolbar menu', (
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

    await tester.pumpWidget(const ServoBrowserApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.enterText(find.byType(TextField), 'https://richyoung.ca');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('bookmark-toggle')));
    await tester.pump(const Duration(milliseconds: 100));

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getStringList('browser.bookmarks'), [
      'https://richyoung.ca',
    ]);

    calls.clear();
    await tester.tap(find.byKey(const ValueKey('bookmarks-menu')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final bookmarkItem = find.byType(PopupMenuItem<String>);
    expect(bookmarkItem, findsOneWidget);
    await tester.tap(bookmarkItem);
    await tester.pump();

    final navigation = calls.lastWhere((call) => call.method == 'setUrl');
    expect(navigation.arguments, ['https://richyoung.ca']);

    await tester.tap(find.byKey(const ValueKey('bookmark-toggle')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(preferences.getStringList('browser.bookmarks'), isEmpty);
  });

  testWidgets('restores persisted bookmarks', (tester) async {
    SharedPreferences.setMockInitialValues({
      'browser.bookmarks': ['https://servo.org'],
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'createTexture' ||
              call.method == 'resizeTexture') {
            return 1;
          }
          return null;
        });

    await tester.pumpWidget(const ServoBrowserApp());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'https://servo.org');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();

    final toggle = tester.widget<IconButton>(
      find.byKey(const ValueKey('bookmark-toggle')),
    );
    expect(toggle.tooltip, 'Remove bookmark');
  });
}
