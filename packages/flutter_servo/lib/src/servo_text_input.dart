import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// A composition client. Servo owns the document and its selection; Flutter owns
/// only the current IME preedit, as in Servo's desktop embedder.
class ServoTextInput with TextInputClient {
  ServoTextInput({required this.sendComposition, required this.sendEnter});

  final Future<void> Function(int id, String state, String text)
  sendComposition;
  final Future<void> Function() sendEnter;
  TextInputConnection? _connection;
  TextEditingValue _value = TextEditingValue.empty;
  bool _composing = false;
  int? _id;
  Future<void> _pending = Future<void>.value();

  bool get attached => _connection?.attached ?? false;
  bool get composing => _composing;

  void open({
    required int id,
    required bool multiline,
    required bool obscureText,
    required bool show,
    required Rect rect,
    required Size size,
    required Matrix4 transform,
  }) {
    if (_id != id) close();
    _id = id;
    if (!attached) {
      _value = TextEditingValue.empty;
      _connection = TextInput.attach(
        this,
        TextInputConfiguration(
          inputType: multiline ? TextInputType.multiline : TextInputType.text,
          obscureText: obscureText,
          autocorrect: false,
          enableSuggestions: false,
          inputAction: multiline
              ? TextInputAction.newline
              : TextInputAction.done,
        ),
      );
      _connection!.setEditingState(_value);
    }
    _connection!.setEditableSizeAndTransform(size, transform);
    _connection!.setCaretRect(rect);
    if (show) _connection!.show();
  }

  void _send(String state, String text) {
    final id = _id!;
    _pending = _pending.then((_) => sendComposition(id, state, text));
    // Report channel errors without leaving an unhandled asynchronous exception.
    _pending = _pending.catchError((Object error, StackTrace stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'flutter_servo',
          context: ErrorDescription('sending IME composition'),
        ),
      );
    });
  }

  void close() {
    if (_composing) _send('end', '');
    _composing = false;
    _connection?.close();
    _connection = null;
    _id = null;
    _value = TextEditingValue.empty;
  }

  @override
  TextEditingValue get currentTextEditingValue => _value;
  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    if (!attached || value == _value) return;
    _value = value;
    if (value.composing.isValid && !value.composing.isCollapsed) {
      if (!_composing) _send('start', '');
      _composing = true;
      _send('update', value.composing.textInside(value.text));
    } else {
      if (!_composing && value.text.isNotEmpty) _send('start', '');
      if (_composing || value.text.isNotEmpty) _send('end', value.text);
      _composing = false;
      _value = TextEditingValue.empty;
      _connection?.setEditingState(_value);
    }
  }

  @override
  void performAction(TextInputAction action) => unawaited(sendEnter());
  @override
  void connectionClosed() => close();
  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}
  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override
  void showAutocorrectionPromptRect(int start, int end) {}
}
