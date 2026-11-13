#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROJECT_DIR="$ROOT_DIR/packages/flutter_servo/example"
cd "$PROJECT_DIR"

mkdir -p "$ROOT_DIR/logs"
LOG_FILE="$ROOT_DIR/logs/gtk4_build_$(date +%Y%m%d_%H%M%S).log"

FLUTTER_BIN=$(command -v "${FLUTTER_BIN:-flutter}" || true)

if [[ ! -x "$FLUTTER_BIN" ]]; then
  echo "Flutter not found. Add the GTK-enabled SDK to PATH or set FLUTTER_BIN." >&2
  exit 1
fi

FLUTTER_BIN=$(readlink -f "$FLUTTER_BIN")
LOCAL_ENGINE_SRC="${LOCAL_ENGINE_SRC:-$(dirname "$(dirname "$FLUTTER_BIN")")/engine/src}"
if [[ ! -d "$LOCAL_ENGINE_SRC" ]]; then
  echo "Local engine source not found: $LOCAL_ENGINE_SRC. Set LOCAL_ENGINE_SRC." >&2
  exit 1
fi

FLUTTER_LINUX_GTK=gtk4 "$FLUTTER_BIN" build linux --debug -v \
  --local-engine=host_debug_unopt \
  --local-engine-host=host_debug_unopt \
  --local-engine-src-path="$LOCAL_ENGINE_SRC" \
  --linux-gtk=gtk4 \
  --dart-define=FLUTTER_LINUX_GTK=gtk4 \
  "$@" 2>&1 | tee -a "$LOG_FILE"
