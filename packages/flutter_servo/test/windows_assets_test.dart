import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';
import 'package:flutter_test/flutter_test.dart';

import '../hook/build.dart' show bundleWindowsAngle;

void main() {
  late Directory profile;
  setUp(() async {
    profile = await Directory.systemTemp.createTemp('servo-windows-assets-');
  });
  tearDown(() async => profile.delete(recursive: true));

  test('bundles both ANGLE DLLs from the Rust profile', () async {
    final angle = Directory.fromUri(
      profile.uri.resolve('build/mozangle-test/out/'),
    );
    await angle.create(recursive: true);
    for (final name in ['libEGL.dll', 'libGLESv2.dll']) {
      await File.fromUri(angle.uri.resolve(name)).writeAsBytes([1, 2, 3]);
    }
    final output = BuildOutputBuilder();
    await bundleWindowsAngle(profile, 'flutter_servo', output);
    final assets = output.build().assets.code;
    expect(
      assets.map((asset) => asset.id),
      unorderedEquals([
        'package:flutter_servo/libEGL.dll',
        'package:flutter_servo/libGLESv2.dll',
      ]),
    );
    expect(
      assets.every((asset) => asset.linkMode is DynamicLoadingBundled),
      isTrue,
    );
    expect(
      assets.every((asset) => File.fromUri(asset.file!).existsSync()),
      isTrue,
    );
  });

  test('rejects a bundle missing a required ANGLE dependency', () async {
    final angle = Directory.fromUri(
      profile.uri.resolve('build/mozangle-test/out/'),
    );
    await angle.create(recursive: true);
    await File.fromUri(angle.uri.resolve('libEGL.dll')).writeAsBytes([1]);
    await expectLater(
      bundleWindowsAngle(profile, 'flutter_servo', BuildOutputBuilder()),
      throwsStateError,
    );
  });

  test('does not combine DLLs from different builds', () async {
    for (final pair in [('a', 'libEGL.dll'), ('b', 'libGLESv2.dll')]) {
      final out = Directory.fromUri(
        profile.uri.resolve('build/mozangle-${pair.$1}/out/'),
      );
      await out.create(recursive: true);
      await File.fromUri(out.uri.resolve(pair.$2)).writeAsBytes([1]);
    }
    final output = BuildOutputBuilder();
    await expectLater(
      bundleWindowsAngle(profile, 'flutter_servo', output),
      throwsStateError,
    );
    expect(output.build().assets.code, isEmpty);
  });

  test('rejects ambiguous complete builds without emitting assets', () async {
    for (final id in ['a', 'b']) {
      final out = Directory.fromUri(
        profile.uri.resolve('build/mozangle-$id/out/'),
      );
      await out.create(recursive: true);
      for (final name in ['libEGL.dll', 'libGLESv2.dll']) {
        await File.fromUri(out.uri.resolve(name)).writeAsBytes([1]);
      }
    }
    final output = BuildOutputBuilder();
    await expectLater(
      bundleWindowsAngle(profile, 'flutter_servo', output),
      throwsStateError,
    );
    expect(output.build().assets.code, isEmpty);
  });

  test('reports a missing Cargo build directory', () async {
    await expectLater(
      bundleWindowsAngle(profile, 'flutter_servo', BuildOutputBuilder()),
      throwsStateError,
    );
  });
}
