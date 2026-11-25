#!/usr/bin/env bash
set -euo pipefail

: "${TARGET:?Set the Cargo target triple}"
: "${RUNNER_TEMP:?Set the Cargo build root parent}"
: "${ARTIFACT:?Set the archive basename}"

build_root="$RUNNER_TEMP"
if [[ "$TARGET" == x86_64-pc-windows-msvc ]]; then
  build_root="$(cygpath -u "$build_root")"
fi
profile="$build_root/servo-native/$TARGET/release"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
destination="${NATIVE_ASSET_DIST:-dist}"
mkdir -p "$destination"

case "$TARGET" in
  x86_64-unknown-linux-gnu|aarch64-unknown-linux-gnu)
    library=librust_lib_flutter_servo.so
    cp "$profile/$library" "$stage/"
    strip --strip-unneeded "$stage/$library"
    nm -D --defined-only "$stage/$library" | awk '
      $NF == "flutter_servo_session_new" { found = 1 }
      END { exit !found }
    '
    ;;
  x86_64-pc-windows-msvc)
    cp "$profile/rust_lib_flutter_servo.dll" "$stage/"
    shopt -s nullglob
    angle=()
    for out in "$profile"/build/mozangle-*/out; do
      if [[ -f "$out/libEGL.dll" && -f "$out/libGLESv2.dll" ]]; then
        angle+=("$out")
      fi
    done
    if (( ${#angle[@]} != 1 )); then
      echo 'Expected exactly one complete ANGLE DLL pair' >&2
      exit 1
    fi
    cp "${angle[0]}/libEGL.dll" "${angle[0]}/libGLESv2.dll" "$stage/"
    ;;
  *) echo "Unsupported target: $TARGET" >&2; exit 1 ;;
esac

printf 'Commit: %s\nTarget: %s\n' "$(git rev-parse HEAD)" "$TARGET" > "$stage/BUILD_INFO.txt"
cp packages/flutter_servo/LICENSE "$stage/LICENSE"
tar -czf "$destination/$ARTIFACT.tar.gz" -C "$stage" .
(cd "$destination" && sha256sum "$ARTIFACT.tar.gz" > "$ARTIFACT.tar.gz.sha256")
