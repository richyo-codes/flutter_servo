# Native Servo Builds

## Dependencies

Servo and its allocator are pinned to commit
`18ead822e67b7660f7ee46cd03e6780940d7cc34` in the public
[Servo fork](https://github.com/richyo-codes/servo), on branch
`fix/windowproxy-inactive-parent-v0.8.0`. This is upstream `v0.8.0` plus the
WindowProxy inactive-parent fix, preserving the full upstream history. Surfman
0.14.0 uses the public [Surfman fork](https://github.com/richyo-codes/surfman)
at commit `0e2cd47b6390eefb6d0ecbb927a34bc03fc0f2cb` from
`fix/no-runtime-env-mutation-v4`. Local Servo or Surfman checkouts and private
SSH credentials are not required; the lockfile records the resolved revisions.

The Surfman patch avoids changing process-wide Mesa environment variables
after Flutter starts threads. It does not force software or PRIME adapter
selection. If needed, set `LIBGL_ALWAYS_SOFTWARE` or `DRI_PRIME` before starting
the app. This remains a downstream workaround pending an upstream solution
that preserves adapter selection without runtime environment mutation. The
problem is tracked in [Surfman #402](https://github.com/servo/surfman/issues/402).

## Source Builds

The Flutter build hook normally compiles Servo. To build the Rust library
directly from the repository root:

```bash
cargo build --release --manifest-path packages/flutter_servo/rust/Cargo.toml --features servo-engine
```

## Precompiled Libraries

**Browser CI** uploads optimized Linux x64 and Windows x64 libraries and
SHA-256 checksums, then reuses the archives for the browser builds. Look for
the downloads in the run's **Artifacts** section. Run **Servo Native Assets**
manually for a library-only build. A `native-vX.Y.Z` tag publishes both libraries
under GitHub Releases.

Use an archive matching your `flutter_servo` package's native code and ABI.
Check `BUILD_INFO.txt` after extraction and verify the archive against its
`.sha256` file before use. Linux builds use GitHub's `ubuntu-latest` runner and
require compatible system libraries. The Windows archive includes the matching ANGLE
DLLs. Flutter still builds the small desktop plugin and application runner.

To download and cache a matching GitHub release at build time, set the tag
in your application's `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    flutter_servo:
      prebuilt_native_tag: native-v0.1.2
```

The hook selects
the archive for the target OS and architecture and checks its SHA-256
sidecar before extracting it into Dart's shared hook cache. A requested
download that fails does not silently fall back to a Rust build.

While the first pub.dev publication is pending, use a pinned Git dependency.
This revision has the corrected pub.dev hook layout and uses the same native
code as the `native-v0.1.2` release:

```yaml
dependencies:
  flutter_servo:
    git:
      url: https://github.com/richyo-codes/flutter_servo.git
      ref: 1184634
      path: packages/flutter_servo
```

For offline builds with an archive you already extracted, use this instead:

```yaml
hooks:
  user_defines:
    flutter_servo:
      prebuilt_native_directory: /absolute/path/to/extracted/archive
```

The hook bundles the libraries without running Cargo. Omit the setting for a
source build. Android and iOS continue using the OS WebView.

The native-assets hook defaults to optimized Rust builds, including when Flutter
is in debug mode. For Rust debugging only, the application's pubspec can override
`hooks.user_defines.flutter_servo.rust_build_mode` to `debug`. Remove that override
before measuring performance or packaging a release.

For profiling an optimized Rust source build, enable line tables in the
application's pubspec. This is off by default to reduce build disk usage.

```yaml
hooks:
  user_defines:
    flutter_servo:
      rust_release_line_tables: true
```

## Bridge Bindings

Generate Rust bridge bindings from the repository root:

```bash
./tools/rebuild_rust_bridge.sh
```

The script uses the repository-root `flutter_rust_bridge.yaml`. If working
from `packages/flutter_servo/` (including in a standalone package checkout),
run `flutter_rust_bridge_codegen generate` there instead. The package-local
configuration targets the same bindings with paths relative to the package.
Run only one of these entry points.
