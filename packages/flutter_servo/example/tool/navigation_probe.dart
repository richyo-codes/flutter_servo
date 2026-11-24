// Desktop integration target: flutter build linux -t tool/navigation_probe.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_servo/flutter_servo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterServo.init();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final origin = 'http://127.0.0.1:${server.port}';
  var denied = false;
  var allowed = false;
  var forbiddenHit = false;
  final result = Completer<bool>();
  void finish(bool ok) {
    if (!result.isCompleted) result.complete(ok);
  }

  server.listen((request) async {
    request.response.headers.contentType = ContentType.html;
    switch (request.uri.path) {
      case '/start':
        request.response.write('''<!doctype html><script>
          setTimeout(() => location.assign('/blocked'), 100);
          setTimeout(() => location.assign('/allowed'), 1000);
        </script>''');
      case '/allowed':
        request.response.write(
          '<!doctype html><title>Policy probe passed</title>',
        );
      case '/blocked':
        forbiddenHit = true;
        finish(false);
      default:
        request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  });
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: FlutterServoSurface.url(
        content: '$origin/start',
        fallback: const SizedBox(),
        allowNavigation: (uri, mainFrame) {
          if (uri.origin != origin) return false;
          if (uri.path == '/blocked') denied = true;
          if (uri.path == '/allowed' && mainFrame == null) allowed = true;
          return uri.path == '/start' || uri.path == '/allowed';
        },
        onTitleChanged: (title) {
          if (title == 'Policy probe passed') {
            finish(denied && allowed && !forbiddenHit);
          }
        },
        onError: (error) {
          stderr.writeln(error);
          finish(false);
        },
      ),
    ),
  );
  final ok = await result.future.timeout(
    const Duration(seconds: 30),
    onTimeout: () => false,
  );
  await server.close(force: true);
  final marker = Platform.environment['FLUTTER_SERVO_PROBE_RESULT'];
  if (marker != null && ok) {
    await File(marker).writeAsString('navigation-verified', flush: true);
  }
  stdout.writeln(
    'Packaged navigation probe: ok=$ok denied=$denied allowed=$allowed forbiddenHit=$forbiddenHit',
  );
  exit(ok ? 0 : 1);
}
