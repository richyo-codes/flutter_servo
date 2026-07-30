import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum FlutterServoContentType {
  url('setUrl'),
  html('setHtml');

  const FlutterServoContentType(this.methodName);

  final String methodName;
}

class FlutterServoSurface extends StatefulWidget {
  const FlutterServoSurface.url({
    super.key,
    required this.content,
    required this.fallback,
    this.enableInputPlumbing = true,
    this.onLoadStateChanged,
    this.reloadRevision = 0,
  }) : contentType = FlutterServoContentType.url;

  const FlutterServoSurface.html({
    super.key,
    required this.content,
    required this.fallback,
    this.enableInputPlumbing = true,
    this.onLoadStateChanged,
    this.reloadRevision = 0,
  }) : contentType = FlutterServoContentType.html;

  final FlutterServoContentType contentType;
  final String content;
  final Widget fallback;
  final bool enableInputPlumbing;
  final ValueChanged<bool>? onLoadStateChanged;
  final int reloadRevision;

  @override
  State<FlutterServoSurface> createState() => _FlutterServoSurfaceState();
}

class _FlutterServoSurfaceState extends State<FlutterServoSurface> {
  static const MethodChannel _channel = MethodChannel('flutter_servo');
  static const Duration _deferredRefreshDelay = Duration(milliseconds: 16);
  static const Duration _resizeSyncDelay = Duration(milliseconds: 80);
  static final Set<_FlutterServoSurfaceState> _loadStateListeners = {};

  final FocusNode _focusNode = FocusNode(debugLabel: 'flutter_servo_surface');
  int? _textureId;
  Size? _logicalSize;
  double? _devicePixelRatio;
  int? _textureWidth;
  int? _textureHeight;
  bool _syncQueued = false;
  bool _deferredRefreshQueued = false;
  Timer? _deferredRefreshTimer;
  Timer? _resizeSyncTimer;
  bool _contentUpdateInFlight = false;
  bool _mouseMoveInFlight = false;
  String? _lastRenderedContent;
  FlutterServoContentType? _lastRenderedContentType;
  int? _lastRenderedRevision;
  int? _activeMouseButton;
  Offset? _pendingMousePosition;

  @override
  void initState() {
    super.initState();
    _loadStateListeners.add(this);
    if (_loadStateListeners.length == 1) {
      _channel.setMethodCallHandler(_handlePlatformMethodCall);
    }
  }

  @override
  void dispose() {
    _deferredRefreshTimer?.cancel();
    _resizeSyncTimer?.cancel();
    _pendingMousePosition = null;
    _loadStateListeners.remove(this);
    if (_loadStateListeners.isEmpty) {
      _channel.setMethodCallHandler(null);
    }
    _focusNode.dispose();
    super.dispose();
  }

  static Future<void> _handlePlatformMethodCall(MethodCall call) async {
    if (call.method != 'loadStateChanged') {
      throw MissingPluginException('Unhandled native method: ${call.method}');
    }

    final isLoading = call.arguments;
    if (isLoading is! bool) {
      throw PlatformException(
        code: 'invalid-load-state',
        message: 'Expected a boolean load state from the Linux plugin.',
      );
    }

    for (final listener in _loadStateListeners.toList()) {
      if (listener.mounted) {
        listener.widget.onLoadStateChanged?.call(isLoading);
      }
    }
  }

  @override
  void didUpdateWidget(covariant FlutterServoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content ||
        oldWidget.contentType != widget.contentType ||
        oldWidget.reloadRevision != widget.reloadRevision) {
      _scheduleTextureSync();
      _requestFocusAfterUpdate();
      _queueDeferredTextureRefresh();
    }
  }

  void _requestFocusAfterUpdate() {
    if (!widget.enableInputPlumbing || widget.content.trim().isEmpty) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
        unawaited(_sendFocusState(true));
      }
    });
  }

  void _queueDeferredTextureRefresh() {
    if (_deferredRefreshQueued) {
      return;
    }

    _deferredRefreshQueued = true;
    _deferredRefreshTimer?.cancel();
    _deferredRefreshTimer = Timer(_deferredRefreshDelay, () {
      _deferredRefreshQueued = false;
      if (mounted) {
        _scheduleTextureSync();
      }
    });
  }

  Future<void> _sendFocusState(bool focused) {
    if (!widget.enableInputPlumbing) {
      return Future<void>.value();
    }

    return _channel.invokeMethod<void>(
      focused ? 'focusWebView' : 'blurWebView',
    );
  }

  void _scheduleTextureSync() {
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
      if (_textureId != null &&
          dimensionsChanged &&
          (_resizeSyncTimer?.isActive ?? false)) {
        return;
      }

      try {
        final hadTexture = _textureId != null;
        var textureId = _textureId;
        if (textureId == null || dimensionsChanged) {
          textureId = await _channel.invokeMethod<int>(
            textureId == null ? 'createTexture' : 'resizeTexture',
            [width, height],
          );
          _textureWidth = width;
          _textureHeight = height;
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
          widget.onLoadStateChanged?.call(true);
          try {
            await _channel.invokeMethod<void>(widget.contentType.methodName, [
              content,
            ]);
          } catch (_) {
            _lastRenderedContent = previousContent;
            _lastRenderedContentType = previousContentType;
            _lastRenderedRevision = previousRevision;
            rethrow;
          } finally {
            _contentUpdateInFlight = false;
            if (mounted) {
              widget.onLoadStateChanged?.call(false);
              _scheduleTextureSync();
              _requestFocusAfterUpdate();
              _queueDeferredTextureRefresh();
            }
          }
        }
      } on MissingPluginException {
        if (!mounted) {
          return;
        }
        setState(() {
          _textureId = null;
          _textureWidth = null;
          _textureHeight = null;
        });
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _scheduleResizeSync() {
    _resizeSyncTimer?.cancel();
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
    _queueDeferredTextureRefresh();
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
    _queueDeferredTextureRefresh();
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

    _queueDeferredTextureRefresh();
    return _channel.invokeMethod<void>('notifyMouseLeaveViewport');
  }

  Future<void> _sendMouseWheel(Offset position, Offset delta) {
    if (!widget.enableInputPlumbing) {
      return Future<void>.value();
    }

    final devicePoint = _toDevicePoint(position);
    _queueDeferredTextureRefresh();
    return _channel.invokeMethod<void>('notifyMouseWheel', [
      devicePoint[0],
      devicePoint[1],
      (delta.dx * (_devicePixelRatio ?? 1.0)).round(),
      (delta.dy * (_devicePixelRatio ?? 1.0)).round(),
    ]);
  }

  Future<void> _sendKeyEvent(KeyEvent event) {
    if (!widget.enableInputPlumbing) {
      return Future<void>.value();
    }

    final isDown = event is KeyDownEvent;
    if (!isDown && event is! KeyUpEvent) {
      return Future<void>.value();
    }

    _queueDeferredTextureRefresh();
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
                child: Texture(textureId: _textureId!),
              );

        if (!widget.enableInputPlumbing) {
          return child;
        }

        return Focus(
          focusNode: _focusNode,
          onFocusChange: (focused) => unawaited(_sendFocusState(focused)),
          onKeyEvent: (node, event) {
            unawaited(_sendKeyEvent(event));
            return KeyEventResult.handled;
          },
          child: MouseRegion(
            onEnter: (_) {
              _focusNode.requestFocus();
              unawaited(_sendFocusState(true));
            },
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
                  unawaited(
                    _sendMouseWheel(event.localPosition, event.scrollDelta),
                  );
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
