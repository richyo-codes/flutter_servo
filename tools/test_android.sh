#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
example_dir="$repo_root/packages/flutter_servo/example"

cd "$example_dir"
flutter test
flutter analyze
flutter build apk --debug

printf 'Android debug APK: %s\n' \
  "$example_dir/build/app/outputs/flutter-apk/app-debug.apk"
