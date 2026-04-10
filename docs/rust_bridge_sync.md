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

```bash
flutter_rust_bridge_codegen generate
cargo build --release --manifest-path rust/Cargo.toml
flutter pub get
flutter build linux
```

## Prevention

- Any change to Rust API structs/functions exposed through FRB must be followed by:
  1. `flutter_rust_bridge_codegen generate`
  2. `cargo build --release --manifest-path rust/Cargo.toml`
- Prefer running `./tools/rebuild_rust_bridge.sh` before local release builds.
