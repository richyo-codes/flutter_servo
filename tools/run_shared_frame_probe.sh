#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_DIR="$ROOT_DIR/.dart_tool/shared_frame_probe"
mkdir -p "$BUILD_DIR"
g++ -std=c++17 -Wall -Wextra \
  "$ROOT_DIR/tools/shared_frame_probe.cc" \
  "$ROOT_DIR/packages/flutter_servo/linux/shared_frame.cc" \
  $(pkg-config --cflags --libs epoxy glib-2.0 gbm) \
  -o "$BUILD_DIR/shared_frame_probe"
"$BUILD_DIR/shared_frame_probe"
"$BUILD_DIR/shared_frame_probe" --cross-display
