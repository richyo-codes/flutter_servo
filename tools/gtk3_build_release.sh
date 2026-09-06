#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROJECT_DIR="$ROOT_DIR/packages/flutter_servo/example"
cd "$PROJECT_DIR"

mkdir -p "$ROOT_DIR/logs"

LOG_FILE="$ROOT_DIR/logs/gtk3_build_release_$(date +%Y%m%d_%H%M%S).log"

FLUTTER_BIN="${FLUTTER_BIN:-/path/to/flutter-gtk4/bin/flutter}"
LOCAL_ENGINE_SRC="${LOCAL_ENGINE_SRC:-/path/to/flutter-gtk4/engine/src}"

if [[ ! -x "$FLUTTER_BIN" ]]; then
  echo "Flutter binary not found or not executable: $FLUTTER_BIN" >&2
  exit 1
fi

FLUTTER_LINUX_GTK=gtk3 "$FLUTTER_BIN" build linux --release -v \
   --local-engine=host_release \
   --local-engine-host=host_release \
   --release \
   --linux-gtk=gtk3 \
   --dart-define=FLUTTER_LINUX_GTK=gtk3 \
   --local-engine-src-path="$LOCAL_ENGINE_SRC" \
   "$@" 2>&1 | tee -a "$LOG_FILE"
