#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[1/5] Generating flutter_rust_bridge bindings..."
flutter_rust_bridge_codegen generate

echo "[2/5] Checking Rust bridge..."
cargo check --manifest-path rust/Cargo.toml

echo "[3/5] Refreshing package dependencies..."
(cd packages/flutter_servo && flutter pub get)

echo "[4/5] Refreshing example dependencies..."
(cd packages/flutter_servo/example && flutter pub get)

echo "[5/5] Done. Flutter builds and bundles Rust through the Native Assets hook."
