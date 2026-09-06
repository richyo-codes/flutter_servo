#!/usr/bin/env bash
set -euo pipefail

# No display connection or screenshots: GL upload calls are replaced in the test.
root="$(cd "$(dirname "$0")/.." && pwd)"
engine_out="${1:?Usage: bash tools/test_linux_texture.sh ENGINE_OUT [gtk3|gtk4]}"
variant="${2:-gtk4}"
case "$variant" in
  gtk3) pkg=gtk+-3.0; library=flutter_linux_gtk; define=FLUTTER_LINUX_GTK3 ;;
  gtk4) pkg=gtk4; library=flutter_linux_gtk4; define=FLUTTER_LINUX_GTK4 ;;
  *) printf 'Unsupported GTK variant: %s\n' "$variant" >&2; exit 2 ;;
esac
engine_out="$(cd "$engine_out" && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
read -r -a pkg_flags <<< "$(pkg-config --cflags --libs "$pkg" epoxy)"
"${CXX:-c++}" -std=c++14 -Wall -Werror -g "-D$define" "-I$engine_out" \
  "$root/packages/flutter_servo/linux/test/servo_texture_test.cc" \
  "-L$engine_out" "-Wl,-rpath,$engine_out" "-l$library" \
  "${pkg_flags[@]}" -o "$test_dir/servo_texture_test"
"$test_dir/servo_texture_test"
