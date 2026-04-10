import 'dart:math' as math;

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
  }) : contentType = FlutterServoContentType.url;

  const FlutterServoSurface.html({
    super.key,
    required this.content,
    required this.fallback,
  }) : contentType = FlutterServoContentType.html;

  final FlutterServoContentType contentType;
  final String content;
  final Widget fallback;

  @override
  State<FlutterServoSurface> createState() => _FlutterServoSurfaceState();
}

class _FlutterServoSurfaceState extends State<FlutterServoSurface> {
  static const MethodChannel _channel = MethodChannel('flutter_servo');

  int? _textureId;
  Size? _logicalSize;
  double? _devicePixelRatio;
  bool _syncQueued = false;
  bool _contentUpdateInFlight = false;
  String? _lastRenderedContent;
  FlutterServoContentType? _lastRenderedContentType;

  @override
  void didUpdateWidget(covariant FlutterServoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content ||
        oldWidget.contentType != widget.contentType) {
      _scheduleTextureSync();
    }
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

        if (_textureId == null) {
          return widget.fallback;
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Texture(textureId: _textureId!),
        );
      },
    );
  }
}
