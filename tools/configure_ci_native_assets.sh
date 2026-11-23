#!/usr/bin/env bash
set -euo pipefail

download_dir="${1:?Pass the native asset download directory}"
pubspec=packages/flutter_servo/example/pubspec.yaml
if grep -q '^hooks:' "$pubspec"; then
  echo "Expected an example pubspec without existing hook settings" >&2
  exit 1
fi

shopt -s nullglob
archives=("$download_dir"/flutter-servo-native-*.tar.gz)
if (( ${#archives[@]} != 1 )); then
  echo "Expected exactly one native asset archive in $download_dir" >&2
  exit 1
fi
archive="${archives[0]}"
(cd "$download_dir" && sha256sum --check --strict "$(basename "$archive").sha256")

mkdir -p .dart_tool
destination="$(mktemp -d "$PWD/.dart_tool/ci-servo-native.XXXXXX")"
tar -xzf "$archive" -C "$destination"
if ! grep -Fxq "Commit: $(git rev-parse HEAD)" "$destination/BUILD_INFO.txt"; then
  echo "Native asset archive does not match the current checkout" >&2
  exit 1
fi

# Git Bash paths are not absolute Windows paths to Dart.
if command -v cygpath >/dev/null; then
  destination="$(cygpath -am "$destination")"
fi
printf "\nhooks:\n  user_defines:\n    flutter_servo:\n      prebuilt_native_directory: '%s'\n" \
  "${destination//\'/\'\'}" >> "$pubspec"
