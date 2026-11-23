import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_servo/src/prebuilt_native_assets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in PrebuiltPlatform.values) {
    test('downloads, verifies and caches ${platform.slug}', () async {
      final cache = await Directory.systemTemp.createTemp(
        'servo-release-test-',
      );
      addTearDown(() => cache.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final releaseBase = Uri.parse('http://127.0.0.1:${server.port}/');
      const tag = 'native-v0.1.2';
      final name = 'flutter-servo-native-${platform.slug}-$tag.tar.gz';
      final archive = Archive();
      for (final library in platform.libraries) {
        archive.addFile(ArchiveFile.bytes('./$library', [1, 2, 3]));
      }
      archive.addFile(ArchiveFile.bytes('../unexpected.dll', [4]));
      final bytes = gzip.encode(TarEncoder().encode(archive));
      var rejectChecksum = true;
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.uri.path);
        if (request.uri.path == '/$tag/$name.sha256') {
          final digest = sha256.convert(rejectChecksum ? <int>[] : bytes);
          request.response.write('$digest  $name\n');
        } else if (request.uri.path == '/$tag/$name') {
          request.response.add(bytes);
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });

      Future<Directory> fetch() => fetchPrebuilt(
        tag: tag,
        platform: platform,
        cache: cache,
        releaseBase: releaseBase,
      );

      await expectLater(fetch(), throwsStateError);
      expect(cache.listSync(), isEmpty);
      rejectChecksum = false;
      final directory = await fetch();
      for (final library in platform.libraries) {
        expect(File.fromUri(directory.uri.resolve(library)).readAsBytesSync(), [
          1,
          2,
          3,
        ]);
      }
      expect(directory.listSync(), hasLength(platform.libraries.length));
      expect((await fetch()).path, directory.path);
      expect(requests, [
        '/$tag/$name.sha256',
        '/$tag/$name',
        '/$tag/$name.sha256',
        '/$tag/$name',
      ]);
    });
  }
}
