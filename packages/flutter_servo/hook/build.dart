import 'dart:io';

import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';
import 'package:code_assets/code_assets.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    // Mobile uses the OS WebView and has no Rust symbols to bundle.
    if (input.config.code.targetOS == OS.android ||
        input.config.code.targetOS == OS.iOS) {
      return;
    }
    final crate = input.packageRoot.resolve('rust/');
    output.dependencies.addAll([
      crate.resolve('Cargo.toml'),
      crate.resolve('Cargo.lock'),
      crate.resolve('rust-toolchain.toml'),
    ]);
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      buildMode: input.userDefines['rust_build_mode'] == 'debug'
          ? FlutterRustBridgeBuildMode.debug
          : FlutterRustBridgeBuildMode.release,
      features:
          input.config.code.targetOS == OS.linux ||
              input.config.code.targetOS == OS.windows
          ? const ['servo-engine']
          : const [],
    ).run(input: input, output: output);
    if (input.config.code.targetOS == OS.windows) {
      // Follow the builder's actual output path (FRB shortens Windows paths).
      final rustAsset = output.build().assets.code.singleWhere(
        (asset) => asset.id.endsWith('/src/rust/frb_generated.io.dart'),
      );
      final profile = File.fromUri(rustAsset.file!).parent;
      await bundleWindowsAngle(profile, input.packageName, output);
    }
  });
}

Future<void> bundleWindowsAngle(
  Directory profile,
  String packageName,
  BuildOutputBuilder output,
) async {
  final buildDirectory = Directory.fromUri(profile.uri.resolve('build/'));
  const names = ['libEGL.dll', 'libGLESv2.dll'];
  final candidates = <Directory>[];
  if (await buildDirectory.exists()) {
    await for (final entry in buildDirectory.list(followLinks: false)) {
      if (entry is! Directory ||
          !entry.uri.pathSegments
              .where((part) => part.isNotEmpty)
              .last
              .startsWith('mozangle-')) {
        continue;
      }
      final out = Directory.fromUri(entry.uri.resolve('out/'));
      if (names.every(
        (name) => File.fromUri(out.uri.resolve(name)).existsSync(),
      )) {
        candidates.add(out);
      }
    }
  }
  if (candidates.length != 1) {
    // Timestamps do not identify the Cargo build linked into the Rust DLL.
    // Fail closed instead of mixing DLL versions or guessing from stale output.
    throw StateError(
      'Expected one complete ANGLE DLL pair in ${buildDirectory.path}; '
      'found ${candidates.length}. Clean this native-assets Cargo output and '
      'rebuild before packaging Windows.',
    );
  }
  for (final name in names) {
    final file = File.fromUri(candidates.single.uri.resolve(name));
    output.assets.code.add(
      CodeAsset(
        package: packageName,
        name: name,
        linkMode: DynamicLoadingBundled(),
        file: file.uri,
      ),
    );
    output.dependencies.add(file.uri);
  }
}
