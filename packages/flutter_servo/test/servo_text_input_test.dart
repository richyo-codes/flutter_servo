import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_servo/src/servo_text_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('IME preedit commits Unicode once and cancels on blur', (
    tester,
  ) async {
    final events = <List<String>>[];
    final client = ServoTextInput(
      sendComposition: (id, state, text) async {
        events.add([state, text]);
      },
      sendEnter: () async {},
    );
    client.open(
      id: 1,
      multiline: false,
      obscureText: false,
      show: true,
      rect: const Rect.fromLTWH(10, 20, 100, 20),
      size: const Size(400, 300),
      transform: Matrix4.identity(),
    );
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        composing: TextRange(start: 0, end: 2),
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '你',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();
    expect(events, [
      ['start', ''],
      ['update', 'ni'],
      ['end', '你'],
    ]);
    expect(client.currentTextEditingValue.text, isEmpty);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'e',
        composing: TextRange(start: 0, end: 1),
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();
    client.close();
    await tester.pump();
    expect(events.last, ['end', '']);
    expect(client.attached, isFalse);
    client.updateEditingValue(const TextEditingValue(text: 'late'));
    await tester.pump();
    expect(events.last, ['end', '']);
  });
}
