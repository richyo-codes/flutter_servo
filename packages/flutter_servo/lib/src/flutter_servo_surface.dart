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
  }) : contentType = FlutterServoContentType.url;

  const FlutterServoSurface.html({
    super.key,
    required this.content,
    required this.fallback,
    this.enableInputPlumbing = true,
  }) : contentType = FlutterServoContentType.html;

  final FlutterServoContentType contentType;
  final String content;
  final Widget fallback;
  final bool enableInputPlumbing;

  @override
  State<FlutterServoSurface> createState() => _FlutterServoSurfaceState();
}

class _FlutterServoSurfaceState extends State<FlutterServoSurface> {
  static const MethodChannel _channel = MethodChannel('flutter_servo');
  static const Duration _deferredRefreshDelay = Duration(milliseconds: 16);

  final FocusNode _focusNode = FocusNode(debugLabel: 'flutter_servo_surface');
  int? _textureId;
  Size? _logicalSize;
  double? _devicePixelRatio;
  bool _syncQueued = false;
  bool _deferredRefreshQueued = false;
  Timer? _deferredRefreshTimer;
  bool _contentUpdateInFlight = false;
  String? _lastRenderedContent;
  FlutterServoContentType? _lastRenderedContentType;
  int? _activeMouseButton;

  @override
  void dispose() {
    _deferredRefreshTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant FlutterServoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content ||
        oldWidget.contentType != widget.contentType) {
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

      try {
        final hadTexture = _textureId != null;
        final textureId = await _channel.invokeMethod<int>(
          _textureId == null ? 'createTexture' : 'resizeTexture',
          [width, height],
        );
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
                _lastRenderedContentType != widget.contentType) &&
            !_contentUpdateInFlight) {
          final previousContent = _lastRenderedContent;
          final previousContentType = _lastRenderedContentType;
          _contentUpdateInFlight = true;
          _lastRenderedContent = content;
          _lastRenderedContentType = widget.contentType;
          try {
            await _channel.invokeMethod<void>(widget.contentType.methodName, [
              content,
            ]);
          } catch (_) {
            _lastRenderedContent = previousContent;
            _lastRenderedContentType = previousContentType;
            rethrow;
          } finally {
            _contentUpdateInFlight = false;
            if (mounted) {
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
        });
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
      delta.dx.round(),
      delta.dy.round(),
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
        _logicalSize = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth : size.width,
          constraints.maxHeight.isFinite ? constraints.maxHeight : size.height,
        );
        _devicePixelRatio = devicePixelRatio;
        _scheduleTextureSync();

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
            onHover: (event) => unawaited(_sendMouseMove(event.position)),
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
                  _sendMouseButton(event.position, _activeMouseButton!, true),
                );
              },
              onPointerMove: (event) =>
                  unawaited(_sendMouseMove(event.position)),
              onPointerUp: (event) {
                unawaited(
                  _sendMouseButton(
                    event.position,
                    _activeMouseButton ?? 0,
                    false,
                  ),
                );
                _activeMouseButton = null;
              },
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  unawaited(_sendMouseWheel(event.position, event.scrollDelta));
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
