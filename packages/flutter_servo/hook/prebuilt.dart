import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

enum PrebuiltPlatform {
  linux('linux-x64', ['librust_lib_flutter_servo.so']),
  windows('windows-x64', [
    'rust_lib_flutter_servo.dll',
    'libEGL.dll',
    'libGLESv2.dll',
  ]);

  const PrebuiltPlatform(this.slug, this.libraries);
  final String slug;
  final List<String> libraries;
}

Future<Directory> fetchPrebuilt({
  required String tag,
  required PrebuiltPlatform platform,
  required Directory cache,
  Uri? releaseBase,
}) async {
  if (!RegExp(r'^native-v[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?$')
          .hasMatch(tag) ||
      tag.endsWith('\n')) {
    throw ArgumentError.value(tag, 'tag', 'Expected native-vX.Y.Z');
  }
  final filename = 'flutter-servo-native-${platform.slug}-$tag.tar.gz';
  final destination = Directory.fromUri(
    cache.uri.resolve('${platform.slug}-$tag/'),
  );
  bool complete() => platform.libraries.every(
    (name) => File.fromUri(destination.uri.resolve(name)).existsSync(),
  );
  if (complete()) return destination;
  await cache.create(recursive: true);
  final staging = await cache.createTemp('fetch-');
  final unpacked = await Directory.fromUri(staging.uri.resolve('payload/'))
      .create();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  final uri =
      (releaseBase ??
              Uri.parse(
                'https://github.com/richyo-codes/flutter_servo/releases/download/',
              ))
          .resolve('$tag/$filename');
  try {
    final checksum = await _response(client, Uri.parse('$uri.sha256'));
    final sidecar = await checksum.transform(utf8.decoder).join();
    final digest = RegExp(r'^([a-fA-F0-9]{64})[ \t]+\*?(\S+)\s*$')
        .firstMatch(sidecar);
    if (digest == null || digest[2] != filename) {
      throw FormatException('Invalid SHA-256 sidecar for $filename');
    }
    final compressed = File.fromUri(staging.uri.resolve(filename));
    await (await _response(client, uri)).pipe(compressed.openWrite());
    final actual = await sha256.bind(compressed.openRead()).first;
    if (actual.toString() != digest[1]!.toLowerCase()) {
      throw StateError('SHA-256 mismatch for $filename');
    }
    final tar = File.fromUri(staging.uri.resolve('payload.tar'));
    await compressed.openRead().transform(gzip.decoder).pipe(tar.openWrite());
    final input = InputFileStream(tar.path);
    try {
      final entries = TarDecoder().decodeStream(input);
      final remaining = platform.libraries.toSet();
      // Extract only the known DLL/SO filenames into our own paths.
      for (final entry in entries) {
        final name = entry.name.startsWith('./')
            ? entry.name.substring(2)
            : entry.name;
        if (!platform.libraries.contains(name)) continue;
        if (!remaining.remove(name) ||
            !entry.isFile ||
            entry.isSymbolicLink ||
            entry.size == 0) {
          throw FormatException('Invalid native archive entry: ${entry.name}');
        }
        final output = OutputFileStream(
          File.fromUri(unpacked.uri.resolve(name)).path,
        );
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
      }
      if (remaining.isNotEmpty) {
        throw FormatException('Missing native archive entries: $remaining');
      }
    } finally {
      await input.close();
    }
    try {
      await unpacked.rename(destination.path);
    } on FileSystemException {
      if (!complete()) rethrow;
    }
    return destination;
  } finally {
    client.close(force: true);
    await staging.delete(recursive: true);
  }
}

Future<Stream<List<int>>> _response(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  final response = await request.close().timeout(const Duration(seconds: 30));
  if (response.statusCode != HttpStatus.ok) {
    throw HttpException(
      'Native release download returned HTTP ${response.statusCode}',
      uri: uri,
    );
  }
  return response.timeout(const Duration(seconds: 30));
}
