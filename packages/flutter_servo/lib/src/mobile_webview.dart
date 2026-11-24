import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'backend.dart';
import 'flutter_servo_surface.dart';

/// OS-managed rendering and input; no Servo texture or input forwarding.
class MobileWebView extends StatefulWidget {
  const MobileWebView({super.key, required this.config});
  final FlutterServoSurface config;

  @override
  State<MobileWebView> createState() => MobileWebViewState();
}

class MobileWebViewState extends State<MobileWebView> {
  WebViewController? _controller;
  bool _ready = false;
  bool _initializing = false;
  bool _failed = false;
  Timer? _timeout;
  int _navigationRevision = 0;
  Future<void> _loads = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  void _progress(FlutterServoLoadProgress progress) {
    if (!mounted) return;
    widget.config.onLoadProgressChanged?.call(progress);
    widget.config.onLoadStateChanged?.call(
      progress == FlutterServoLoadProgress.started,
    );
  }

  void _started() {
    if (!mounted) return;
    _failed = false;
    _timeout?.cancel();
    final duration = widget.config.loadTimeout;
    if (duration != null) {
      _timeout = Timer(
        duration,
        () => _error('load-timeout', 'WebView loading timed out.'),
      );
    }
    _progress(FlutterServoLoadProgress.started);
  }

  void _error(String code, String message) {
    if (!mounted) return;
    _failed = true;
    _timeout?.cancel();
    _progress(FlutterServoLoadProgress.failed);
    widget.config.onError?.call(
      PlatformException(code: code, message: message),
    );
  }

  Future<void> _initialize() async {
    if (!mounted || _initializing) return;
    _initializing = true;
    try {
      final legacy = widget.config.controller == null;
      if (legacy && BackendSession.webview != null) {
        throw StateError(
          'Only one mobile surface is supported by the static navigation API.',
        );
      }
      final controller = WebViewController();
      _controller = controller;
      if (legacy) BackendSession.webview = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!mounted) return;
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => _started(),
          onPageFinished: (_) {
            if (!mounted || _failed) return;
            _timeout?.cancel();
            _progress(FlutterServoLoadProgress.complete);
            unawaited(_navigation());
          },
          onUrlChange: (_) => unawaited(_navigation()),
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) {
              _error('webview-load-failed', error.description);
            }
          },
        ),
      );
      if (!mounted) return;
      setState(() => _ready = true);
      _queueLoad();
    } catch (error) {
      if (identical(BackendSession.webview, _controller)) {
        BackendSession.webview = null;
      }
      _controller = null;
      _error('webview-init-failed', error.toString());
    } finally {
      _initializing = false;
    }
  }

  Future<bool> navigate(String command) async {
    await _loads;
    final controller = _controller;
    if (!mounted || !_ready || controller == null) return false;
    switch (command) {
      case 'goBack':
        if (!await controller.canGoBack() || !mounted) return false;
        await controller.goBack();
      case 'goForward':
        if (!await controller.canGoForward() || !mounted) return false;
        await controller.goForward();
      case 'reload':
        await controller.reload();
      default:
        return false;
    }
    return true;
  }

  Future<void> _navigation() async {
    final revision = ++_navigationRevision;
    final controller = _controller;
    if (!mounted || controller == null) return;
    try {
      final url = await controller.currentUrl() ?? '';
      final back = await controller.canGoBack();
      final forward = await controller.canGoForward();
      if (!mounted || revision != _navigationRevision) return;
      widget.config.onNavigationStateChanged?.call(
        FlutterServoNavigationState(
          url: url,
          canGoBack: back,
          canGoForward: forward,
        ),
      );
    } catch (error) {
      if (mounted) _error('webview-navigation-failed', error.toString());
    }
  }

  void _queueLoad() {
    final config = widget.config;
    // Serialize commands so a slower HTML load cannot overtake a later URL.
    _loads = _loads.then((_) async {
      if (!mounted) return;
      try {
        _started();
        if (config.contentType == FlutterServoContentType.html) {
          await _controller!.loadHtmlString(config.content);
        } else {
          await _controller!.loadRequest(Uri.parse(config.content));
        }
      } catch (error) {
        _error('webview-load-failed', error.toString());
      }
    });
  }

  @override
  void didUpdateWidget(MobileWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config.controller != widget.config.controller) {
      if (widget.config.controller != null &&
          identical(BackendSession.webview, _controller)) {
        BackendSession.webview = null;
      } else if (widget.config.controller == null &&
          BackendSession.webview == null) {
        BackendSession.webview = _controller;
      }
    }
    if (oldWidget.config.content != widget.config.content ||
        oldWidget.config.contentType != widget.config.contentType ||
        oldWidget.config.reloadRevision != widget.config.reloadRevision) {
      if (_ready) {
        _queueLoad();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
      }
    }
  }

  @override
  void dispose() {
    _timeout?.cancel();
    if (identical(BackendSession.webview, _controller)) {
      BackendSession.webview = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !_ready
      ? widget.config.fallback
      : IgnorePointer(
          ignoring: !widget.config.enableInputPlumbing,
          child: WebViewWidget(controller: _controller!),
        );
}
