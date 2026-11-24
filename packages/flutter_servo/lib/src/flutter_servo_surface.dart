import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'servo_text_input.dart';
import 'servo_page_semantics.dart';
import 'backend.dart';
import 'mobile_webview.dart';

enum FlutterServoContentType {
  url('setUrl'),
  html('setHtml');

  const FlutterServoContentType(this.methodName);

  final String methodName;
}

enum FlutterServoLoadProgress { started, firstFrame, complete, failed }

class FlutterServoNavigationState {
  const FlutterServoNavigationState({
    required this.url,
    required this.canGoBack,
    required this.canGoForward,
  });

  final String url;
  final bool canGoBack;
  final bool canGoForward;
}

/// Imperative controls for one mounted [FlutterServoSurface].
///
/// Load and zoom requests update the surface on its next build. Use the
/// surface's progress and error callbacks to observe the result.
class FlutterServoController {
  _BackendSurfaceState? _surface;

  bool get isAttached => _surface != null;

  _BackendSurfaceState get _attached =>
      _surface ?? (throw StateError('FlutterServoController is not attached.'));

  void loadUrl(Uri url) =>
      _attached._load(FlutterServoContentType.url, url.toString());

  void loadHtml(String html) =>
      _attached._load(FlutterServoContentType.html, html);

  Future<bool> goBack() => _attached._navigate('goBack');

  Future<bool> goForward() => _attached._navigate('goForward');

  Future<bool> reload() => _attached._navigate('reload');

  /// Set desktop page zoom between 0.5 and 3.0.
  void setZoom(double zoom) => _attached._setZoom(zoom);
}

class FlutterServoSurface extends StatefulWidget {
  FlutterServoSurface._copy(
    FlutterServoSurface config, {
    super.key,
    FlutterServoContentType? contentTypeOverride,
    String? contentOverride,
    int? reloadRevisionOverride,
    double? zoomOverride,
  }) : contentType = contentTypeOverride ?? config.contentType,
       content = contentOverride ?? config.content,
       fallback = config.fallback,
       enableInputPlumbing = config.enableInputPlumbing,
       enableContextMenu = config.enableContextMenu,
       onLoadStateChanged = config.onLoadStateChanged,
       onLoadProgressChanged = config.onLoadProgressChanged,
       onNavigationStateChanged = config.onNavigationStateChanged,
       onWheelZoom = config.onWheelZoom,
       onError = config.onError,
       loadTimeout = config.loadTimeout,
       reloadRevision = reloadRevisionOverride ?? config.reloadRevision,
       pageZoom = zoomOverride ?? config.pageZoom,
       controller = config.controller,
       backend = config.backend;

  const FlutterServoSurface.url({
    super.key,
    required this.content,
    required this.fallback,
    this.enableInputPlumbing = true,
    this.enableContextMenu = false,
    this.onLoadStateChanged,
    this.onLoadProgressChanged,
    this.onNavigationStateChanged,
    this.onWheelZoom,
    this.onError,
    this.loadTimeout = const Duration(seconds: 30),
    this.reloadRevision = 0,
    this.pageZoom = 1.0,
    this.controller,
    this.backend,
  }) : assert(pageZoom >= 0.5 && pageZoom <= 3.0),
       contentType = FlutterServoContentType.url;

  const FlutterServoSurface.html({
    super.key,
    required this.content,
    required this.fallback,
    this.enableInputPlumbing = true,
    this.enableContextMenu = false,
    this.onLoadStateChanged,
    this.onLoadProgressChanged,
    this.onNavigationStateChanged,
    this.onWheelZoom,
    this.onError,
    this.loadTimeout = const Duration(seconds: 30),
    this.reloadRevision = 0,
    this.pageZoom = 1.0,
    this.controller,
    this.backend,
  }) : assert(pageZoom >= 0.5 && pageZoom <= 3.0),
       contentType = FlutterServoContentType.html;

  final FlutterServoContentType contentType;
  final String content;
  final Widget fallback;
  final bool enableInputPlumbing;

  /// Shows Servo's page-specific context menu; requires a Material host.
  final bool enableContextMenu;
  final ValueChanged<bool>? onLoadStateChanged;
  final ValueChanged<FlutterServoLoadProgress>? onLoadProgressChanged;
  final ValueChanged<FlutterServoNavigationState>? onNavigationStateChanged;

  /// Optional desktop Ctrl+wheel handler: +1 zooms in, -1 zooms out.
  /// Without a handler, Ctrl+wheel is forwarded to Servo like other scrolling.
  final ValueChanged<int>? onWheelZoom;
  final ValueChanged<PlatformException>? onError;

  /// Maximum wait for completion after native loading starts; null disables it.
  final Duration? loadTimeout;
  final int reloadRevision;

  /// Desktop Servo page zoom, from 0.5 to 3.0. The OS WebView ignores this.
  final double pageZoom;
  final FlutterServoController? controller;
  final FlutterServoBackend? backend;

  @override
  State<FlutterServoSurface> createState() => _BackendSurfaceState();
}

class _BackendSurfaceState extends State<FlutterServoSurface> {
  static _BackendSurfaceState? _nativeOwner;
  static final _waiting = <_BackendSurfaceState>{};

  void _releaseNative() {
    if (_nativeOwner != this) return;
    _nativeOwner = null;
    if (_waiting.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_nativeOwner != null) return;
      for (final surface in _waiting) {
        if (surface.mounted) surface.setState(() {});
      }
    });
  }
  final _nativeKey = GlobalKey<_FlutterServoSurfaceState>();
  final _mobileKey = GlobalKey<MobileWebViewState>();
  bool _reportedUnsupported = false;
  FlutterServoBackend? _backend;
  FlutterServoContentType? _contentType;
  String? _content;
  double? _zoom;
  int _loadRevision = 0;

  @override
  void initState() {
    super.initState();
    _attach(widget.controller);
  }

  void _attach(FlutterServoController? controller) {
    if (controller == null) return;
    if (controller._surface != null && controller._surface != this) {
      throw StateError(
        'A FlutterServoController can control only one surface.',
      );
    }
    controller._surface = this;
  }

  void _detach(FlutterServoController? controller) {
    if (controller?._surface == this) controller!._surface = null;
  }

  @override
  void didUpdateWidget(FlutterServoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      _attach(widget.controller);
      _detach(oldWidget.controller);
      _contentType = null;
      _content = null;
      _zoom = null;
    }
    if (widget.content != oldWidget.content ||
        widget.contentType != oldWidget.contentType) {
      _contentType = null;
      _content = null;
    }
    if (widget.pageZoom != oldWidget.pageZoom) _zoom = null;
  }

  @override
  void dispose() {
    _detach(widget.controller);
    _waiting.remove(this);
    _releaseNative();
    super.dispose();
  }

  void _load(FlutterServoContentType type, String content) {
    if (_backend == null) throw StateError('No browser backend is available.');
    setState(() {
      _contentType = type;
      _content = content;
      _loadRevision++;
    });
  }

  void _setZoom(double zoom) {
    if (_backend != FlutterServoBackend.servo) {
      throw UnsupportedError('Page zoom requires the desktop Servo backend.');
    }
    if (!zoom.isFinite || zoom < 0.5 || zoom > 3.0) {
      throw ArgumentError.value(zoom, 'zoom', 'Must be between 0.5 and 3.0.');
    }
    setState(() => _zoom = zoom);
  }

  Future<bool> _navigate(String command) async {
    if (_backend == FlutterServoBackend.webview) {
      return await _mobileKey.currentState?.navigate(command) ?? false;
    }
    final native = _nativeKey.currentState;
    if (_nativeOwner != this || native?._textureId == null) return false;
    return await _FlutterServoSurfaceState._channel.invokeMethod<bool>(
          command,
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final backend = resolveFlutterServoBackend(
      widget.backend ?? BackendSession.preference,
    );
    final nativeBusy =
        backend == FlutterServoBackend.servo &&
        _nativeOwner != null &&
        _nativeOwner != this;
    _backend = nativeBusy ? null : backend;
    if (nativeBusy) {
      _waiting.add(this);
    } else {
      _waiting.remove(this);
    }
    if (backend != FlutterServoBackend.servo) _releaseNative();
    if (backend == null || nativeBusy) {
      if (!_reportedUnsupported) {
        _reportedUnsupported = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          widget.onLoadStateChanged?.call(false);
          widget.onLoadProgressChanged?.call(FlutterServoLoadProgress.failed);
          widget.onError?.call(
            PlatformException(
              code: nativeBusy ? 'servo-session-in-use' : 'unsupported-backend',
              message: nativeBusy
                  ? 'Only one desktop Servo surface can be mounted at a time.'
                  : 'The requested browser backend is unavailable on this platform.',
            ),
          );
        });
      }
      return widget.fallback;
    }
    _reportedUnsupported = false;
    final config = FlutterServoSurface._copy(
      widget,
      contentTypeOverride: _contentType,
      contentOverride: _content,
      reloadRevisionOverride: widget.reloadRevision + _loadRevision,
      zoomOverride: _zoom,
    );
    if (backend == FlutterServoBackend.servo) _nativeOwner = this;
    return backend == FlutterServoBackend.webview
        ? MobileWebView(key: _mobileKey, config: config)
        : _NativeSurface(config, key: _nativeKey);
  }
}

class _NativeSurface extends FlutterServoSurface {
  _NativeSurface(super.config, {super.key}) : super._copy();

  @override
  State<FlutterServoSurface> createState() => _FlutterServoSurfaceState();
}

class _FlutterServoSurfaceState extends State<FlutterServoSurface> {
  static const MethodChannel _channel = MethodChannel('flutter_servo');
  static const Duration _deferredRefreshDelay = Duration(milliseconds: 32);
  static const Duration _refreshRetryDelay = Duration(milliseconds: 100);
  static const int _maxRefreshAttempts = 20;
  static const Duration _resizeSyncDelay = Duration(milliseconds: 40);
  static final Set<_FlutterServoSurfaceState> _loadStateListeners = {};

  final FocusNode _focusNode = FocusNode(debugLabel: 'flutter_servo_surface');
  int? _textureId;
  bool _hasFrame = false;
  MouseCursor _cursor = SystemMouseCursors.basic;
  Size? _logicalSize;
  double? _devicePixelRatio;
  int? _textureWidth;
  double? _appliedDisplayScale;
  double? _appliedPageZoom;
  int? _textureHeight;
  bool _syncQueued = false;
  bool _textureSyncInFlight = false;
  bool _textureSyncRequested = false;
  bool _loadFailed = false;
  Timer? _loadTimeoutTimer;
  bool _deferredRefreshQueued = false;
  bool _refreshInFlight = false;
  bool _refreshRequested = false;
  int _refreshAttemptsRemaining = 0;
  Timer? _deferredRefreshTimer;
  Timer? _resizeSyncTimer;
  bool _contentUpdateInFlight = false;
  bool _mouseMoveInFlight = false;
  bool _wheelInFlight = false;
  String? _lastRenderedContent;
  FlutterServoContentType? _lastRenderedContentType;
  int? _lastRenderedRevision;
  int? _activeMouseButton;
  Offset? _pendingMousePosition;
  Offset? _pendingWheelPosition;
  Offset _pendingWheelDelta = Offset.zero;
  int? _menuId;
  PopupRoute<int>? _menuRoute;
  final Set<PhysicalKeyboardKey> _imeKeys = {};
  List<Object?> _accessibilityNodes = const [];
  bool _accessibilityEnabled = false;
  late final ServoTextInput _textInput = ServoTextInput(
    sendComposition: (id, state, text) => _respondToControl({
      'type': 'composition',
      'id': id,
      'state': state,
      'text': text,
    }),
    sendEnter: () async {
      await _channel.invokeMethod<void>('notifyKeyEvent', ['Enter', '', true]);
      await _channel.invokeMethod<void>('notifyKeyEvent', ['Enter', '', false]);
    },
  );

  Future<void> _respondToControl(Map<String, Object?> response) async {
    await _channel.invokeMethod<bool>('respondToControl', jsonEncode(response));
  }

  void _onSemanticsChanged() {
    if (!SemanticsBinding.instance.semanticsEnabled &&
        _accessibilityNodes.isNotEmpty) {
      setState(() => _accessibilityNodes = const []);
    }
    _scheduleTextureSync();
  }

  Future<void> _syncAccessibility() async {
    final enable = SemanticsBinding.instance.semanticsEnabled;
    if (enable == _accessibilityEnabled) return;
    final accepted = await _channel.invokeMethod<bool>(
      'respondToControl',
      jsonEncode({'type': 'accessibilityEnabled', 'enabled': enable}),
    );
    if (mounted && accepted == true) _accessibilityEnabled = enable;
  }

  void _hideMenu() {
    final route = _menuRoute;
    _menuRoute = null;
    _menuId = null;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
  }

  void _handleControl(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'cursor':
        final cursor = switch (event['cursor']) {
          'None' => SystemMouseCursors.none,
          'Pointer' => SystemMouseCursors.click,
          'ContextMenu' => SystemMouseCursors.contextMenu,
          'Help' => SystemMouseCursors.help,
          'Progress' => SystemMouseCursors.progress,
          'Wait' => SystemMouseCursors.wait,
          'Cell' => SystemMouseCursors.cell,
          'Crosshair' => SystemMouseCursors.precise,
          'Text' => SystemMouseCursors.text,
          'VerticalText' => SystemMouseCursors.verticalText,
          'Alias' => SystemMouseCursors.alias,
          'Copy' => SystemMouseCursors.copy,
          'Move' => SystemMouseCursors.move,
          'NoDrop' => SystemMouseCursors.noDrop,
          'NotAllowed' => SystemMouseCursors.forbidden,
          'Grab' => SystemMouseCursors.grab,
          'Grabbing' => SystemMouseCursors.grabbing,
          'EResize' => SystemMouseCursors.resizeRight,
          'NResize' => SystemMouseCursors.resizeUp,
          'NeResize' => SystemMouseCursors.resizeUpRight,
          'NwResize' => SystemMouseCursors.resizeUpLeft,
          'SResize' => SystemMouseCursors.resizeDown,
          'SeResize' => SystemMouseCursors.resizeDownRight,
          'SwResize' => SystemMouseCursors.resizeDownLeft,
          'WResize' => SystemMouseCursors.resizeLeft,
          'EwResize' => SystemMouseCursors.resizeLeftRight,
          'NsResize' => SystemMouseCursors.resizeUpDown,
          'NeswResize' => SystemMouseCursors.resizeUpRightDownLeft,
          'NwseResize' => SystemMouseCursors.resizeUpLeftDownRight,
          'ColResize' => SystemMouseCursors.resizeColumn,
          'RowResize' => SystemMouseCursors.resizeRow,
          'AllScroll' => SystemMouseCursors.allScroll,
          'ZoomIn' => SystemMouseCursors.zoomIn,
          'ZoomOut' => SystemMouseCursors.zoomOut,
          _ => SystemMouseCursors.basic,
        };
        if (_cursor != cursor) setState(() => _cursor = cursor);
      case 'accessibilityTree':
        if (event['nodes'] case final List<Object?> nodes
            when SemanticsBinding.instance.semanticsEnabled) {
          setState(() => _accessibilityNodes = nodes);
        }
      case 'contextMenu':
        unawaited(_showPageMenu(event));
      case 'hideContextMenu':
        if (_menuId == event['id']) _hideMenu();
      case 'hideIme':
        _textInput.close();
      case 'ime':
        if (!_focusNode.hasFocus ||
            !widget.enableInputPlumbing ||
            _loadFailed) {
          return;
        }
        final box = context.findRenderObject()! as RenderBox;
        final scale = _devicePixelRatio ?? 1;
        _textInput.open(
          id: event['id'] as int,
          multiline: event['multiline'] == true,
          obscureText: event['inputType'] == 'Password',
          show: event['show'] == true,
          rect: Rect.fromLTWH(
            (event['x'] as num) / scale,
            (event['y'] as num) / scale,
            (event['width'] as num) / scale,
            (event['height'] as num) / scale,
          ),
          size: box.size,
          transform: box.getTransformTo(null),
        );
    }
  }

  Future<void> _showPageMenu(Map<String, dynamic> event) async {
    final id = event['id'] as int;
    if (!widget.enableContextMenu ||
        !widget.enableInputPlumbing ||
        _loadFailed ||
        (event['items'] as List).isEmpty) {
      await _respondToControl({'type': 'contextMenu', 'id': id, 'index': null});
      return;
    }
    _hideMenu();
    _menuId = id;
    final surface = context.findRenderObject()! as RenderBox;
    final scale = _devicePixelRatio ?? 1;
    final globalPosition = surface.localToGlobal(
      Offset((event['x'] as num) / scale, (event['y'] as num) / scale),
    );
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = overlay.globalToLocal(globalPosition);
    final colors = Theme.of(context).colorScheme;
    final index = await showMenu<int>(
      context: context,
      requestFocus: false,
      color: colors.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      menuPadding: const EdgeInsets.symmetric(vertical: 5),
      constraints: const BoxConstraints(minWidth: 176, maxWidth: 320),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final item in event['items'] as List)
          if (item['separator'] == true)
            const PopupMenuDivider(height: 9, indent: 10, endIndent: 10)
          else
            PopupMenuItem<int>(
              value: item['index'] as int,
              enabled: item['enabled'] == true,
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Builder(
                builder: (context) {
                  _menuRoute = ModalRoute.of(context) as PopupRoute<int>;
                  return Text(item['label'] as String);
                },
              ),
            ),
      ],
    );
    if (!mounted || _menuId != id) return;
    _menuRoute = null;
    _menuId = null;
    await _respondToControl({'type': 'contextMenu', 'id': id, 'index': index});
  }

  @override
  void initState() {
    super.initState();
    SemanticsBinding.instance.addSemanticsEnabledListener(_onSemanticsChanged);
    _loadStateListeners.add(this);
    if (_loadStateListeners.length == 1) {
      _channel.setMethodCallHandler(_handlePlatformMethodCall);
    }
  }

  @override
  void dispose() {
    SemanticsBinding.instance.removeSemanticsEnabledListener(
      _onSemanticsChanged,
    );
    _hideMenu();
    _textInput.close();
    _loadTimeoutTimer?.cancel();
    _deferredRefreshTimer?.cancel();
    _resizeSyncTimer?.cancel();
    _pendingMousePosition = null;
    _pendingWheelPosition = null;
    _loadStateListeners.remove(this);
    if (_loadStateListeners.isEmpty) {
      if (_accessibilityEnabled) {
        unawaited(
          _respondToControl({'type': 'accessibilityEnabled', 'enabled': false})
              .onError<PlatformException>((_, _) {})
              .onError<MissingPluginException>((_, _) {}),
        );
      }
      _channel.setMethodCallHandler(null);
    }
    _focusNode.dispose();
    super.dispose();
  }

  static Future<void> _handlePlatformMethodCall(MethodCall call) async {
    if (call.method == 'frameAvailable') {
      for (final listener in _loadStateListeners.toList()) {
        if (listener.mounted && !listener._hasFrame) {
          listener.setState(() => listener._hasFrame = true);
        }
      }
      return;
    }
    if (call.method == 'embedderControl') {
      final event =
          jsonDecode(call.arguments as String) as Map<String, dynamic>;
      for (final listener in _loadStateListeners.toList()) {
        if (listener.mounted) listener._handleControl(event);
      }
      return;
    }
    if (call.method == 'navigationStateChanged') {
      final arguments = call.arguments;
      if (arguments is! List ||
          arguments.length != 3 ||
          arguments[0] is! String ||
          arguments[1] is! bool ||
          arguments[2] is! bool) {
        throw PlatformException(
          code: 'invalid-navigation-state',
          message:
              'Expected [url, canGoBack, canGoForward] from the native plugin.',
        );
      }
      final state = FlutterServoNavigationState(
        url: arguments[0] as String,
        canGoBack: arguments[1] as bool,
        canGoForward: arguments[2] as bool,
      );
      for (final listener in _loadStateListeners.toList()) {
        if (listener.mounted) {
          listener.widget.onNavigationStateChanged?.call(state);
        }
      }
      return;
    }

    if (call.method != 'loadStateChanged') {
      throw MissingPluginException('Unhandled native method: ${call.method}');
    }

    final value = call.arguments;
    final FlutterServoLoadProgress progress;
    if (value is int &&
        value >= 0 &&
        value < FlutterServoLoadProgress.values.length) {
      progress = FlutterServoLoadProgress.values[value];
    } else if (value is bool) {
      progress = value
          ? FlutterServoLoadProgress.started
          : FlutterServoLoadProgress.complete;
    } else {
      throw PlatformException(
        code: 'invalid-load-state',
        message: 'Expected a load progress value from the native plugin.',
      );
    }

    for (final listener in _loadStateListeners.toList()) {
      if (listener.mounted) {
        if (progress == FlutterServoLoadProgress.failed) {
          listener._reportError(
            PlatformException(
              code: 'servo-crashed',
              message:
                  'Servo stopped rendering this page. Try loading it again.',
            ),
          );
          continue;
        }
        if (listener._loadFailed) {
          continue;
        }
        if (progress == FlutterServoLoadProgress.started) {
          listener._startLoadTimeout();
        } else if (progress == FlutterServoLoadProgress.complete) {
          listener._loadTimeoutTimer?.cancel();
          listener._loadTimeoutTimer = null;
        }
        listener.widget.onLoadProgressChanged?.call(progress);
        listener.widget.onLoadStateChanged?.call(
          progress != FlutterServoLoadProgress.complete,
        );
      }
    }
  }

  void _startLoadTimeout() {
    if (_loadTimeoutTimer != null || widget.loadTimeout == null) return;
    _loadTimeoutTimer = Timer(widget.loadTimeout!, () {
      if (mounted) {
        _reportError(
          PlatformException(
            code: 'servo-load-timeout',
            message: 'The page did not finish loading. Try again.',
          ),
        );
      }
    });
  }

  void _reportError(PlatformException error) {
    if (_loadFailed) return;
    _loadFailed = true;
    _textInput.close();
    _hideMenu();
    _focusNode.unfocus();
    _pendingMousePosition = null;
    _pendingWheelPosition = null;
    _pendingWheelDelta = Offset.zero;
    _loadTimeoutTimer?.cancel();
    _loadTimeoutTimer = null;
    _deferredRefreshTimer?.cancel();
    _deferredRefreshQueued = false;
    _refreshRequested = false;
    widget.onLoadProgressChanged?.call(FlutterServoLoadProgress.failed);
    widget.onLoadStateChanged?.call(false);
    widget.onError?.call(error);
  }

  @override
  void didUpdateWidget(covariant FlutterServoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageZoom != widget.pageZoom) _scheduleTextureSync();
    if (oldWidget.enableInputPlumbing && !widget.enableInputPlumbing) {
      _textInput.close();
      _focusNode.unfocus();
    }
    if (oldWidget.content != widget.content ||
        oldWidget.contentType != widget.contentType ||
        oldWidget.reloadRevision != widget.reloadRevision) {
      _textInput.close();
      final retryingFailure = _loadFailed;
      _loadFailed = false;
      _loadTimeoutTimer?.cancel();
      _loadTimeoutTimer = null;
      // The plugin may suppress a repeated "started" value on a stalled retry.
      if (retryingFailure) _startLoadTimeout();
      _scheduleTextureSync();
      _queueDeferredTextureRefresh();
    }
  }

  void _queueDeferredTextureRefresh() {
    if (_loadFailed) return;
    _refreshAttemptsRemaining = _maxRefreshAttempts;
    _refreshRequested = true;
    _scheduleDeferredTextureRefresh(_deferredRefreshDelay);
  }

  void _scheduleDeferredTextureRefresh(Duration delay) {
    if (_deferredRefreshQueued) {
      return;
    }

    _deferredRefreshQueued = true;
    _deferredRefreshTimer?.cancel();
    _deferredRefreshTimer = Timer(delay, () async {
      _deferredRefreshQueued = false;
      if (!mounted ||
          _loadFailed ||
          _textureId == null ||
          widget.content.trim().isEmpty) {
        return;
      }
      if (_contentUpdateInFlight) {
        _scheduleDeferredTextureRefresh(_refreshRetryDelay);
        return;
      }
      if (_refreshInFlight) {
        _refreshRequested = true;
        return;
      }

      _refreshInFlight = true;
      _refreshRequested = false;
      var retry = false;
      try {
        await _channel.invokeMethod<bool>('refreshTexture');
      } on MissingPluginException {
        // The fallback remains visible on unsupported platforms.
      } on PlatformException {
        if (mounted && !_loadFailed && _refreshAttemptsRemaining > 0) {
          _refreshAttemptsRemaining--;
          retry = true;
        }
      } finally {
        _refreshInFlight = false;
        if (mounted && !_loadFailed && (retry || _refreshRequested)) {
          _scheduleDeferredTextureRefresh(
            retry ? _refreshRetryDelay : _deferredRefreshDelay,
          );
        }
      }
    });
  }

  Future<void> _sendFocusState(bool focused) {
    if (!focused) _textInput.close();
    if (!widget.enableInputPlumbing) {
      return Future<void>.value();
    }

    return _channel.invokeMethod<void>(
      focused ? 'focusWebView' : 'blurWebView',
    );
  }

  void _scheduleTextureSync() {
    if (_textureSyncInFlight) {
      _textureSyncRequested = true;
      return;
    }
    if (_syncQueued || _logicalSize == null || _devicePixelRatio == null) {
      return;
    }

    _syncQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _syncQueued = false;

      final logicalSize = _logicalSize;
      final devicePixelRatio = _devicePixelRatio;
      if (!mounted || logicalSize == null || devicePixelRatio == null) {
        return;
      }

      final width = math.max(1, (logicalSize.width * devicePixelRatio).round());
      final height = math.max(
        1,
        (logicalSize.height * devicePixelRatio).round(),
      );
      final dimensionsChanged =
          _textureWidth != width || _textureHeight != height;
      final pageZoom = widget.pageZoom;
      final scaleChanged =
          _appliedDisplayScale != devicePixelRatio ||
          _appliedPageZoom != pageZoom;
      if (_textureId != null &&
          dimensionsChanged &&
          (_resizeSyncTimer?.isActive ?? false)) {
        return;
      }

      _textureSyncInFlight = true;
      try {
        final hadTexture = _textureId != null;
        var textureId = _textureId;
        if (textureId == null || dimensionsChanged || scaleChanged) {
          textureId = await _channel.invokeMethod<int>(
            textureId == null ? 'createTexture' : 'resizeTexture',
            [width, height, devicePixelRatio, pageZoom],
          );
          _textureWidth = width;
          _textureHeight = height;
          _appliedDisplayScale = devicePixelRatio;
          _appliedPageZoom = pageZoom;
        }
        if (!mounted) {
          return;
        }

        if (textureId != null && _textureId != textureId) {
          setState(() {
            _textureId = textureId;
          });
        }

        final content = widget.content.trim();
        if (content.isEmpty) {
          return;
        }

        // Let Flutter present at least one frame with the new texture before
        // kicking off the heavier native content update.
        if (!hadTexture && textureId != null) {
          _scheduleTextureSync();
          return;
        }

        if ((_lastRenderedContent != content ||
                _lastRenderedContentType != widget.contentType ||
                _lastRenderedRevision != widget.reloadRevision) &&
            !_contentUpdateInFlight) {
          final previousContent = _lastRenderedContent;
          final previousContentType = _lastRenderedContentType;
          final previousRevision = _lastRenderedRevision;
          _contentUpdateInFlight = true;
          _lastRenderedContent = content;
          _lastRenderedContentType = widget.contentType;
          _lastRenderedRevision = widget.reloadRevision;
          var loaded = false;
          try {
            await _channel.invokeMethod<void>(widget.contentType.methodName, [
              content,
            ]);
            loaded = true;
          } catch (_) {
            _lastRenderedContent = previousContent;
            _lastRenderedContentType = previousContentType;
            _lastRenderedRevision = previousRevision;
            rethrow;
          } finally {
            _contentUpdateInFlight = false;
            if (mounted && loaded) {
              _scheduleTextureSync();
              _queueDeferredTextureRefresh();
            }
          }
        }
        if (mounted) await _syncAccessibility();
      } on MissingPluginException {
        if (!mounted) {
          return;
        }
        setState(() {
          _textureId = null;
          _textureWidth = null;
          _textureHeight = null;
        });
      } on PlatformException catch (error) {
        if (mounted) {
          _reportError(error);
        }
      } finally {
        _textureSyncInFlight = false;
        if (mounted && _textureSyncRequested) {
          _textureSyncRequested = false;
          _scheduleTextureSync();
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _scheduleResizeSync() {
    if (_resizeSyncTimer?.isActive ?? false) return;
    _resizeSyncTimer = Timer(_resizeSyncDelay, () {
      _resizeSyncTimer = null;
      if (mounted) {
        _scheduleTextureSync();
      }
    });
  }

  Future<void> _sendMouseMove(Offset position) {
    if (!widget.enableInputPlumbing) {
      return Future<void>.value();
    }

    final devicePoint = _toDevicePoint(position);
    return _channel.invokeMethod<void>('notifyMouseMove', devicePoint);
  }

  void _queueMouseMove(Offset position) {
    _pendingMousePosition = position;
    if (!_mouseMoveInFlight) {
      unawaited(_drainMouseMoves());
    }
  }

  Future<void> _drainMouseMoves() async {
    _mouseMoveInFlight = true;
    try {
      while (mounted && _pendingMousePosition != null) {
        final position = _pendingMousePosition!;
        _pendingMousePosition = null;
        await _sendMouseMove(position);
      }
    } finally {
      _mouseMoveInFlight = false;
      if (mounted && _pendingMousePosition != null) {
        unawaited(_drainMouseMoves());
      }
    }
  }

  Future<void> _sendMouseButton(Offset position, int button, bool isDown) {
    if (!widget.enableInputPlumbing) {
      return Future<void>.value();
    }

    final devicePoint = _toDevicePoint(position);
    return _channel.invokeMethod<void>('notifyMouseButton', [
      devicePoint[0],
      devicePoint[1],
      button,
      isDown,
    ]);
  }

  int _mapMouseButtonsToServoButton(int buttons) {
    if (buttons == kPrimaryButton) {
      return 0;
    }
    if (buttons == kMiddleMouseButton) {
      return 1;
    }
    if (buttons == kSecondaryButton) {
      return 2;
    }
    if (buttons == kBackMouseButton) {
      return 3;
    }
    if (buttons == kForwardMouseButton) {
      return 4;
    }
    return 0;
  }

  Future<void> _sendMouseLeave() {
    if (!widget.enableInputPlumbing) {
      return Future<void>.value();
    }

    return _channel.invokeMethod<void>('notifyMouseLeaveViewport');
  }

  Future<void> _sendMouseWheel(Offset position, Offset delta) {
    if (!widget.enableInputPlumbing) {
      return Future<void>.value();
    }

    final devicePoint = _toDevicePoint(position);
    // Servo expects content-motion deltas, opposite to Flutter scroll offsets.
    return _channel.invokeMethod<void>('notifyMouseWheel', [
      devicePoint[0],
      devicePoint[1],
      (-delta.dx * (_devicePixelRatio ?? 1.0)).round(),
      (-delta.dy * (_devicePixelRatio ?? 1.0)).round(),
    ]);
  }

  void _queueMouseWheel(Offset position, Offset delta) {
    _pendingWheelPosition = position;
    _pendingWheelDelta += delta;
    if (!_wheelInFlight) {
      unawaited(_drainMouseWheel());
    }
  }

  Future<void> _drainMouseWheel() async {
    _wheelInFlight = true;
    try {
      while (mounted && _pendingWheelPosition != null) {
        final position = _pendingWheelPosition!;
        final delta = _pendingWheelDelta;
        _pendingWheelPosition = null;
        _pendingWheelDelta = Offset.zero;
        await _sendMouseWheel(position, delta);
      }
    } finally {
      _wheelInFlight = false;
      if (mounted && _pendingWheelPosition != null) {
        unawaited(_drainMouseWheel());
      }
    }
  }

  Future<void> _sendKeyEvent(KeyEvent event) {
    if (!widget.enableInputPlumbing) {
      return Future<void>.value();
    }

    final isDown = event is KeyDownEvent || event is KeyRepeatEvent;
    if (!isDown && event is! KeyUpEvent) {
      return Future<void>.value();
    }

    return _channel.invokeMethod<void>('notifyKeyEvent', [
      event.logicalKey.keyLabel,
      event.character ?? '',
      isDown,
    ]);
  }

  List<int> _toDevicePoint(Offset position) {
    final devicePixelRatio = _devicePixelRatio ?? 1.0;
    return [
      (position.dx * devicePixelRatio).round(),
      (position.dy * devicePixelRatio).round(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final logicalSize = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth : size.width,
          constraints.maxHeight.isFinite ? constraints.maxHeight : size.height,
        );
        final sizeChanged =
            _logicalSize != logicalSize ||
            _devicePixelRatio != devicePixelRatio;
        _logicalSize = logicalSize;
        _devicePixelRatio = devicePixelRatio;
        if (_textureId == null) {
          _scheduleTextureSync();
        } else if (sizeChanged) {
          _scheduleResizeSync();
        }

        final child = _textureId == null
            ? widget.fallback
            : ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Texture(textureId: _textureId!),
                    if (!_hasFrame) widget.fallback,
                    if (_hasFrame &&
                        !_loadFailed &&
                        _accessibilityNodes.isNotEmpty)
                      ServoPageSemantics(
                        nodes: _accessibilityNodes,
                        displayScale: devicePixelRatio,
                        onActivate: widget.enableInputPlumbing
                            ? (id) => unawaited(
                                _respondToControl({
                                  'type': 'accessibilityAction',
                                  'id': id,
                                  'action': 'Click',
                                }),
                              )
                            : null,
                      ),
                  ],
                ),
              );

        if (!widget.enableInputPlumbing) {
          return child;
        }

        return Focus(
          focusNode: _focusNode,
          onFocusChange: (focused) => unawaited(_sendFocusState(focused)),
          onKeyEvent: (node, event) {
            if (event is KeyUpEvent && _imeKeys.remove(event.physicalKey)) {
              return KeyEventResult.ignored;
            }
            // Let the engine's text input plugin process text and IME preedit.
            // Navigation and shortcuts continue through Servo's keyboard path.
            final modified =
                HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed ||
                HardwareKeyboard.instance.isAltPressed;
            if (_textInput.attached &&
                !modified &&
                (_textInput.composing ||
                    event.character?.isNotEmpty == true ||
                    event.logicalKey.keyLabel.runes.length == 1 ||
                    event.logicalKey == LogicalKeyboardKey.compose ||
                    event.logicalKey == LogicalKeyboardKey.space)) {
              if (event is! KeyUpEvent) _imeKeys.add(event.physicalKey);
              return KeyEventResult.ignored;
            }
            unawaited(_sendKeyEvent(event));
            return KeyEventResult.handled;
          },
          child: MouseRegion(
            cursor: _cursor,
            onHover: (event) => _queueMouseMove(event.localPosition),
            onExit: (_) => unawaited(_sendMouseLeave()),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                _focusNode.requestFocus();
                unawaited(_sendFocusState(true));
                _activeMouseButton = _mapMouseButtonsToServoButton(
                  event.buttons,
                );
                unawaited(
                  _sendMouseButton(
                    event.localPosition,
                    _activeMouseButton!,
                    true,
                  ),
                );
              },
              onPointerMove: (event) => _queueMouseMove(event.localPosition),
              onPointerUp: (event) {
                unawaited(
                  _sendMouseButton(
                    event.localPosition,
                    _activeMouseButton ?? 0,
                    false,
                  ),
                );
                _activeMouseButton = null;
              },
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  final zoom = widget.onWheelZoom;
                  if (zoom != null &&
                      HardwareKeyboard.instance.isControlPressed &&
                      event.scrollDelta.dy != 0) {
                    GestureBinding.instance.pointerSignalResolver.register(
                      event,
                      (_) => zoom(event.scrollDelta.dy < 0 ? 1 : -1),
                    );
                    return;
                  }
                  _queueMouseWheel(event.localPosition, event.scrollDelta);
                }
              },
              child: child,
            ),
          ),
        );
      },
    );
  }
}
