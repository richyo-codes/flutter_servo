// Android smoke target for the OS WebView and native listener installation.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_servo/flutter_servo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterServo.init(backend: FlutterServoBackend.webview);
  final result = Completer<bool>();
  const attachment = String.fromEnvironment('PROBE_ATTACHMENT_URL');
  var completed = false;
  var titled = false;
  var downloaded = false;
  final status = ValueNotifier<String>('Waiting for attachment notification');
  void check() {
    if (completed &&
        titled &&
        (attachment.isEmpty || downloaded) &&
        !result.isCompleted) {
      result.complete(true);
    }
  }

  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xff202020),
        child: SafeArea(
          child: Column(
            children: [
              ValueListenableBuilder<String>(
                valueListenable: status,
                builder: (_, text, _) => Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Color(0xffffffff),
                      fontSize: 18,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: FlutterServoSurface.html(
                  content:
                      '<!doctype html><title>Native WebView probe</title>'
                      '<meta name="viewport" content="width=device-width, initial-scale=1">'
                      '<body style="padding:24px;font:20px sans-serif">'
                      '<a onclick="document.querySelector(\'p\').textContent=\'Tap received by page\'" '
                      'href="${const HtmlEscape().convert(attachment)}">Test attachment</a>'
                      '<p>Tap the link above.</p>',
                  fallback: const SizedBox(),
                  onLoadProgressChanged: (state) {
                    completed = state == FlutterServoLoadProgress.complete;
                    check();
                  },
                  onTitleChanged: (title) {
                    titled = title == 'Native WebView probe';
                    check();
                  },
                  onDownloadRequested: (url, mimeType, length) {
                    downloaded =
                        attachment.isNotEmpty && url == Uri.parse(attachment);
                    status.value = downloaded
                        ? 'Download callback received (no file saved)'
                        : 'Received a different attachment URL';
                    debugPrint(
                      'Attachment notification: match=$downloaded mime=$mimeType bytes=$length',
                    );
                    check();
                  },
                  onError: (error) {
                    status.value = 'WebView error: ${error.code}';
                    debugPrint('Mobile WebView probe error: ${error.code}');
                    if (!result.isCompleted) result.complete(false);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  final ok = await result.future.timeout(
    const Duration(seconds: 30),
    onTimeout: () => false,
  );
  debugPrint(
    'Mobile WebView probe: ok=$ok complete=$completed title=$titled download=$downloaded',
  );
}
