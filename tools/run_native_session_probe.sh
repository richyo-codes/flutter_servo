#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.dart_tool/native_session_probe"
SOURCE_FILE="$ROOT_DIR/tools/native_session_probe.cc"
OUTPUT_FILE="$BUILD_DIR/native_session_probe"
LIBRARY_PATH_DEFAULT="$ROOT_DIR/packages/flutter_servo/example/build/linux/x64/debug/bundle/lib/librust_lib_flutter_servo.so"

mkdir -p "$BUILD_DIR"

GTK_CFLAGS="$(pkg-config --cflags gtk+-3.0)"
GTK_LIBS="$(pkg-config --libs gtk+-3.0)"

g++ -std=c++17 -O0 -g "$SOURCE_FILE" -o "$OUTPUT_FILE" -ldl $GTK_CFLAGS $GTK_LIBS

LIBRARY_PATH="${1:-$LIBRARY_PATH_DEFAULT}"
shift $(( $# > 0 ? 1 : 0 ))

exec "$OUTPUT_FILE" "$@" "$LIBRARY_PATH"
