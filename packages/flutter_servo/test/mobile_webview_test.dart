import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_servo/flutter_servo.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class FakeController extends PlatformWebViewController {
  FakeController(super.params) : super.implementation();
  String? url;
  String? html;
  int reloads = 0;
  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate delegate,
  ) async {}
  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    url = params.uri.toString();
  }

  @override
  Future<void> loadHtmlString(String value, {String? baseUrl}) async {
    html = value;
  }

  @override
  Future<String?> currentUrl() async => url;
  @override
  Future<bool> canGoBack() async => true;
  @override
  Future<bool> canGoForward() async => false;
  @override
  Future<void> goBack() async {
    url = 'https://example.com/back';
  }

  @override
  Future<void> reload() async {
    reloads++;
  }
}

class FakeDelegate extends PlatformNavigationDelegate {
  FakeDelegate(super.params) : super.implementation();
  PageEventCallback? started;
  PageEventCallback? finished;
  WebResourceErrorCallback? error;
  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async {
    started = callback;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async {
    finished = callback;
  }

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {
    error = callback;
  }

  @override
  Future<void> setOnUrlChange(UrlChangeCallback callback) async {}
}

class FakeWidget extends PlatformWebViewWidget {
  FakeWidget(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) =>
      const SizedBox(key: ValueKey('os-webview'));
}

class FakeWebView extends WebViewPlatform {
  late FakeController controller;
  late FakeDelegate delegate;
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => controller = FakeController(params);
  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => delegate = FakeDelegate(params);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => FakeWidget(params);
}

void main() {
  test('auto selects only implemented backends', () {
    for (final target in TargetPlatform.values) {
      final expected = switch (target) {
        TargetPlatform.android ||
        TargetPlatform.iOS => FlutterServoBackend.webview,
        TargetPlatform.linux ||
        TargetPlatform.windows => FlutterServoBackend.servo,
        _ => null,
      };
      expect(
        resolveFlutterServoBackend(FlutterServoBackend.auto, platform: target),
        expected,
      );
    }
    expect(
      resolveFlutterServoBackend(
        FlutterServoBackend.servo,
        platform: TargetPlatform.android,
      ),
      isNull,
    );
    expect(
      resolveFlutterServoBackend(
        FlutterServoBackend.webview,
        platform: TargetPlatform.linux,
      ),
      isNull,
    );
    expect(
      resolveFlutterServoBackend(FlutterServoBackend.auto, isWeb: true),
      isNull,
    );
  });

  for (final target in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$target controllers keep WebView navigation separate', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = target;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final platform = FakeWebView();
      WebViewPlatform.instance = platform;
      final first = FlutterServoController();
      final second = FlutterServoController();
      Widget surface(FlutterServoController controller, String url) => Expanded(
        child: FlutterServoSurface.url(
          controller: controller,
          content: url,
          fallback: const SizedBox(),
        ),
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            children: [
              surface(first, 'https://example.com/first'),
              surface(second, 'https://example.com/second'),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('os-webview')), findsNWidgets(2));
      final secondView = platform.controller;
      expect(secondView.url, 'https://example.com/second');
      expect(await first.reload(), isTrue);
      expect(secondView.reloads, 0);
      expect(await second.goBack(), isTrue);
      expect(secondView.url, 'https://example.com/back');
      expect(() => second.setZoom(1.5), throwsUnsupportedError);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(first.isAttached, isFalse);
      expect(second.isAttached, isFalse);
    });

    testWidgets('$target uses OS WebView and routes navigation without Servo', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = target;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final platform = FakeWebView();
      WebViewPlatform.instance = platform;
      await FlutterServo.init();
      final nativeCalls = <String>[];
      const channel = MethodChannel('flutter_servo');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        nativeCalls.add(call.method);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final progress = <FlutterServoLoadProgress>[];
      final errors = <PlatformException>[];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: FlutterServoSurface.url(
            content: 'https://example.com',
            fallback: const SizedBox(),
            onLoadProgressChanged: progress.add,
            onError: errors.add,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('os-webview')), findsOneWidget);
      expect(platform.controller.url, 'https://example.com');
      expect(await FlutterServo.goBack(), isTrue);
      expect(await FlutterServo.goForward(), isFalse);
      expect(await FlutterServo.reload(), isTrue);
      expect(platform.controller.reloads, 1);
      platform.delegate.finished!('https://example.com');
      expect(progress.last, FlutterServoLoadProgress.complete);
      platform.delegate.started!('https://example.com/fail');
      platform.delegate.error!(
        WebResourceError(
          errorCode: -1,
          description: 'failed',
          isForMainFrame: true,
        ),
      );
      platform.delegate.finished!('https://example.com/fail');
      expect(progress.last, FlutterServoLoadProgress.failed);
      expect(errors.single.code, 'webview-load-failed');
      expect(
        () => FlutterServo.setProxySettings(httpProxyUri: 'http://proxy'),
        throwsUnsupportedError,
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: FlutterServoSurface.html(
            content: '<h1>Offline</h1>',
            fallback: const SizedBox(),
            loadTimeout: const Duration(milliseconds: 50),
            onError: errors.add,
          ),
        ),
      );
      await tester.pump();
      expect(platform.controller.html, '<h1>Offline</h1>');
      await tester.pump(const Duration(milliseconds: 60));
      expect(errors.last.code, 'load-timeout');
      await tester.pumpWidget(const SizedBox());
      expect(await FlutterServo.reload(), isFalse);
      expect(nativeCalls, isEmpty);
    });
  }
}
