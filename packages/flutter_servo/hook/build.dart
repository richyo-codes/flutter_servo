import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';
import 'package:code_assets/code_assets.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final crate = input.packageRoot.resolve('../../rust/');
    output.dependencies.addAll([
      crate.resolve('Cargo.toml'),
      crate.resolve('Cargo.lock'),
      crate.resolve('rust-toolchain.toml'),
    ]);
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: '../../rust',
      buildMode: input.userDefines['rust_build_mode'] == 'debug'
          ? FlutterRustBridgeBuildMode.debug
          : FlutterRustBridgeBuildMode.release,
      features: input.config.code.targetOS == OS.linux
          ? const ['servo-engine']
          : const [],
    ).run(input: input, output: output);
  });
}
