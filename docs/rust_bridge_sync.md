# Rust/FRB Sync Troubleshooting

## Symptom

The Flutter app builds, but runtime bridge calls fail or stale generated APIs do
not match the Rust library.

## One-command Fix

From repo root:

```bash
./tools/rebuild_rust_bridge.sh
```

Then fully restart the app process.

## Manual Fix

From the repository root (using the root generator config):

```bash
flutter_rust_bridge_codegen generate
cargo build --release --manifest-path packages/flutter_servo/rust/Cargo.toml
cd packages/flutter_servo/example
flutter pub get
flutter build linux
```

## Prevention

- Any change to Rust API structs/functions exposed through FRB must be followed by:
  1. `flutter_rust_bridge_codegen generate` from the repo root
  2. `cargo build --release --manifest-path packages/flutter_servo/rust/Cargo.toml`
- Prefer running `./tools/rebuild_rust_bridge.sh` before local release builds.
