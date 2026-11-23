#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
MANIFEST="$ROOT_DIR/flatpak/ca.richyoung.flutter_servo_browser.yml"
APP_ID="ca.richyoung.flutter_servo_browser"
CONTAINER_ROOT="/src"
CONTAINER_MANIFEST="$CONTAINER_ROOT/flatpak/ca.richyoung.flutter_servo_browser.yml"
CONTAINER_BUILD_DIR="$CONTAINER_ROOT/build/flatpak"
CONTAINER_REPO_DIR="$CONTAINER_ROOT/build/flatpak-repo"
CONTAINER_BUNDLE_PATH="$CONTAINER_ROOT/build/ca.richyoung.flutter_servo_browser.flatpak"
CONTAINER_ID=""
DEFAULT_OUT_DIR="/tmp/flutter-servo-browser-flatpak"

usage() {
  cat <<'EOF'
Usage: ./tools/build_flatpak_container.sh [--out-dir PATH]

  --out-dir PATH  Store Flatpak builder artifacts under PATH.
EOF
}

OUT_DIR="$DEFAULT_OUT_DIR"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      if [[ $# -lt 2 ]]; then
        echo "--out-dir requires a path." >&2
        exit 1
      fi
      OUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd -P)
BUILD_DIR="$OUT_DIR/flatpak"
REPO_DIR="$OUT_DIR/flatpak-repo"
BUNDLE_PATH="$OUT_DIR/ca.richyoung.flutter_servo_browser.flatpak"

if [[ ! -f "$MANIFEST" ]]; then
  echo "Flatpak manifest not found: $MANIFEST" >&2
  exit 1
fi

if command -v podman >/dev/null 2>&1; then
  ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then
  ENGINE="docker"
else
  echo "Neither podman nor docker was found in PATH." >&2
  exit 1
fi

IMAGE="ghcr.io/flathub-infra/flatpak-builder-lint:latest"

HOST_BUNDLE_DIR="$ROOT_DIR/packages/flutter_servo/example/build/linux/x64/release/bundle"
if [[ ! -f "$HOST_BUNDLE_DIR/flutter_servo_example" ]]; then
  echo "Missing $HOST_BUNDLE_DIR/flutter_servo_example. Run: flutter build linux --release --project-dir packages/flutter_servo/example" >&2
  exit 1
fi

TTY_ARGS=(-i)
if [[ -t 1 ]]; then
  TTY_ARGS+=(-t)
fi

cleanup() {
  if [[ -n "$CONTAINER_ID" ]]; then
    "$ENGINE" rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

CREATE_ARGS=(
  create
  "${TTY_ARGS[@]}"
  --privileged
  --device
  /dev/fuse
  --security-opt
  label=disable
  --entrypoint
  /bin/bash
  "$IMAGE"
  -lc
  "sleep infinity"
)

CONTAINER_ID=$("$ENGINE" "${CREATE_ARGS[@]}")
"$ENGINE" start "$CONTAINER_ID" >/dev/null
"$ENGINE" exec "$CONTAINER_ID" mkdir -p "$CONTAINER_ROOT"
"$ENGINE" cp "$ROOT_DIR/." "$CONTAINER_ID:$CONTAINER_ROOT"

"$ENGINE" exec "${TTY_ARGS[@]}" "$CONTAINER_ID" /bin/bash -lc "
  set -euo pipefail
  flatpak-builder --version
  if [[ ! -f '$CONTAINER_MANIFEST' ]]; then
    echo 'Missing Flatpak manifest inside container:' '$CONTAINER_MANIFEST' >&2
    ls -la '$CONTAINER_ROOT' >&2 || true
    ls -la '$CONTAINER_ROOT/flatpak' >&2 || true
    exit 1
  fi
  dbus-uuidgen --ensure=/etc/machine-id
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  flatpak remotes || true
  flatpak --system install -y --noninteractive --no-related flathub \
    org.freedesktop.Sdk/x86_64/25.08 \
    org.freedesktop.Platform/x86_64/25.08

  flatpak-builder --disable-rofiles-fuse --force-clean '$CONTAINER_BUILD_DIR' '$CONTAINER_MANIFEST'
  flatpak-builder --disable-rofiles-fuse --force-clean --repo='$CONTAINER_REPO_DIR' '$CONTAINER_BUILD_DIR' '$CONTAINER_MANIFEST'
  flatpak build-bundle '$CONTAINER_REPO_DIR' '$CONTAINER_BUNDLE_PATH' '$APP_ID'
"

rm -rf "$BUILD_DIR" "$REPO_DIR" "$BUNDLE_PATH"
"$ENGINE" cp "$CONTAINER_ID:$CONTAINER_BUILD_DIR" "$BUILD_DIR"
"$ENGINE" cp "$CONTAINER_ID:$CONTAINER_REPO_DIR" "$REPO_DIR"
"$ENGINE" cp "$CONTAINER_ID:$CONTAINER_BUNDLE_PATH" "$BUNDLE_PATH"

echo "Flatpak bundle created: $BUNDLE_PATH"
echo "Install with: flatpak install --user --reinstall $BUNDLE_PATH"
