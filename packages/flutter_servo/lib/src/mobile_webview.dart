import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'backend.dart';
import 'flutter_servo_surface.dart';

bool authorizeGeolocation(String rawOrigin, bool Function(Uri)? policy) {
  if (policy == null) return false;
  try {
    final uri = Uri.parse(rawOrigin);
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      return false;
    }
    return policy(Uri.parse(uri.origin));
  } catch (_) {
    return false;
  }
}

List<String> androidUploadUris(List<Uri> files, bool multiple) {
  if ((!multiple && files.length > 1) ||
      files.any(
        (uri) =>
            uri.scheme != 'content' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            uri.path.isEmpty,
      )) {
    return [];
  }
  return files.map((uri) => uri.toString()).toList(growable: false);
}

/// OS-managed rendering and input; no Servo texture or input forwarding.
class MobileWebView extends StatefulWidget {
  const MobileWebView({super.key, required this.config});
  final FlutterServoSurface config;

  @override
  State<MobileWebView> createState() => MobileWebViewState();
}

class MobileWebViewState extends State<MobileWebView> {
  WebViewController? _controller;
  MethodChannel? _downloadEvents;
  bool _ready = false;
  bool _initializing = false;
  bool _failed = false;
  Timer? _timeout;
  int _navigationRevision = 0;
  int _pickerEpoch = 0;
  bool _pickerOpen = false;
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
    _navigationRevision++;
    _pickerEpoch++;
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
    _navigationRevision++;
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
      final controller = WebViewController(
        onPermissionRequest: (request) async {
          try {
            await request.deny();
          } on PlatformException {
            // A canceled native request cannot be answered or reported as denied.
            return;
          }
          if (mounted) {
            widget.config.onPermissionDenied?.call(
              Set.unmodifiable(request.types.map((type) => type.name)),
            );
          }
        },
      );
      _controller = controller;
      if (controller.platform case final AndroidWebViewController android) {
        await android.setOnShowFileSelector(_pickFiles);
        if (!mounted) return;
        await android.setGeolocationPermissionsPromptCallbacks(
          onShowPrompt: (request) async => GeolocationPermissionsResponse(
            allow:
                mounted &&
                authorizeGeolocation(
                  request.origin,
                  widget.config.allowGeolocation,
                ),
            retain: false,
          ),
        );
        if (!mounted) return;
      }
      if (legacy) BackendSession.webview = navigate;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!mounted) return;
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onProgress: (percent) {
            if (mounted && !_failed && percent >= 0 && percent <= 100) {
              widget.config.onLoadPercentChanged?.call(percent);
            }
          },
          onNavigationRequest: (request) =>
              _allows(request.url, request.isMainFrame)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
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
      if (controller.platform case final AndroidWebViewController android) {
        final id = android.webViewIdentifier;
        final events = MethodChannel('flutter_servo/android_downloads/$id');
        _downloadEvents = events;
        events.setMethodCallHandler((call) async {
          if (!mounted || !_ready || call.method != 'download') return;
          final data = call.arguments as Map;
          final url = Uri.tryParse(data['url'] as String? ?? '');
          if (url == null ||
              url.scheme != 'https' ||
              url.host.isEmpty ||
              url.userInfo.isNotEmpty) {
            return;
          }
          final length = data['contentLength'] as int?;
          widget.config.onDownloadRequested?.call(
            url,
            data['mimeType'] as String?,
            length != null && length >= 0 ? length : null,
          );
        });
        await const MethodChannel('flutter_servo/android_downloads')
            .invokeMethod<void>('install', id);
        if (!mounted) return;
      }
      setState(() => _ready = true);
      _queueLoad();
    } catch (error) {
      if (BackendSession.webview == navigate) {
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
    // The platform cannot preflight a history destination or a reload replay.
    // Protected hosts can issue a fresh URL load through the policy instead.
    if (widget.config.allowNavigation != null) return false;
    switch (command) {
      case 'goBack':
        if (!await controller.canGoBack() ||
            !mounted ||
            widget.config.allowNavigation != null) {
          return false;
        }
        await controller.goBack();
      case 'goForward':
        if (!await controller.canGoForward() ||
            !mounted ||
            widget.config.allowNavigation != null) {
          return false;
        }
        await controller.goForward();
      case 'reload':
        await controller.reload();
      default:
        return false;
    }
    return true;
  }

  Future<List<String>> _pickFiles(FileSelectorParams params) async {
    if (!mounted ||
        !_ready ||
        _failed ||
        _pickerOpen ||
        params.isCaptureEnabled ||
        params.mode == FileSelectorMode.save) {
      return [];
    }
    final picker = widget.config.onPickUploadFiles;
    if (picker == null) return [];
    final epoch = _pickerEpoch;
    final multiple = params.mode == FileSelectorMode.openMultiple;
    _pickerOpen = true;
    try {
      final files = await picker(
        List.unmodifiable(params.acceptTypes),
        multiple,
      );
      if (!mounted ||
          _failed ||
          epoch != _pickerEpoch ||
          widget.config.onPickUploadFiles != picker) {
        return [];
      }
      return androidUploadUris(files, multiple);
    } catch (_) {
      return [];
    } finally {
      _pickerOpen = false;
    }
  }

  Future<void> clearCookies() async {
    if (!_ready) throw StateError('WebView is not ready.');
    await WebViewCookieManager().clearCookies();
  }

  Future<void> _navigation() async {
    final revision = ++_navigationRevision;
    final controller = _controller;
    if (!mounted || controller == null) return;
    FlutterServoNavigationState? state;
    try {
      final url = await controller.currentUrl() ?? '';
      final back = await controller.canGoBack();
      final forward = await controller.canGoForward();
      state = FlutterServoNavigationState(
        url: url,
        canGoBack: back,
        canGoForward: forward,
      );
    } catch (_) {
      // A missing history snapshot does not mean the document failed to load.
    }
    if (!mounted || revision != _navigationRevision || _failed) return;
    if (state != null) widget.config.onNavigationStateChanged?.call(state);
    if (widget.config.onTitleChanged != null) {
      String? title;
      try {
        title = await controller.getTitle();
      } catch (_) {
        return;
      }
      if (mounted && revision == _navigationRevision && !_failed) {
        widget.config.onTitleChanged?.call(title);
      }
    }
  }

  void _queueLoad() {
    final config = widget.config;
    // Serialize commands so a slower HTML load cannot overtake a later URL.
    _loads = _loads.then((_) async {
      if (!mounted) return;
      try {
        if (widget.config.allowNavigation != null &&
            (config.contentType == FlutterServoContentType.html ||
                !_allows(config.content, true))) {
          _error(
            'navigation-denied',
            'The host navigation policy denied the load.',
          );
          return;
        }
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

  bool _allows(String value, bool mainFrame) {
    if (!mounted) return false;
    final policy = widget.config.allowNavigation;
    if (policy == null) return true;
    final url = Uri.tryParse(value);
    if (url == null || !url.hasScheme) return false;
    try {
      return policy(url, mainFrame);
    } catch (_) {
      return false;
    }
  }

  @override
  void didUpdateWidget(MobileWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config.controller != widget.config.controller ||
        oldWidget.config.onPickUploadFiles != widget.config.onPickUploadFiles ||
        oldWidget.config.content != widget.config.content ||
        oldWidget.config.reloadRevision != widget.config.reloadRevision) {
      _pickerEpoch++;
    }
    if (oldWidget.config.controller != widget.config.controller) {
      if (widget.config.controller != null &&
          BackendSession.webview == navigate) {
        BackendSession.webview = null;
      } else if (widget.config.controller == null &&
          BackendSession.webview == null &&
          _controller != null) {
        BackendSession.webview = navigate;
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
    _downloadEvents?.setMethodCallHandler(null);
    _timeout?.cancel();
    if (BackendSession.webview == navigate) {
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
