#!/usr/bin/env bash
set -euo pipefail

bundle="${1:?Usage: $0 /path/to/release/bundle [gtk3|gtk4]}"
variant="${2:-gtk4}"
case "$variant" in
  gtk3) engine=libflutter_linux_gtk.so; other_engine=libflutter_linux_gtk4.so; gtk=3; other_gtk=4 ;;
  gtk4) engine=libflutter_linux_gtk4.so; other_engine=libflutter_linux_gtk.so; gtk=4; other_gtk=3 ;;
  *) echo "Invalid GTK variant: $variant" >&2; exit 2 ;;
esac
binary="$bundle/flutter_servo_example"
for file in "$binary" "$bundle/lib/libapp.so" \
  "$bundle/lib/$engine" \
  "$bundle/lib/libflutter_servo_plugin.so" \
  "$bundle/lib/librust_lib_flutter_servo.so" \
  "$bundle/data/icudtl.dat"; do
  if [[ ! -f "$file" ]]; then
    echo "GTK$gtk release bundle is missing $file" >&2
    exit 1
  fi
done
test -x "$binary"
test -d "$bundle/data/flutter_assets"
if [[ -e "$bundle/lib/$other_engine" ]]; then
  echo "GTK$gtk bundle contains the GTK$other_gtk Flutter engine" >&2
  exit 1
fi

# Check the dlopened Servo library as well as the executable's dependency tree.
for elf in "$binary" "$bundle"/lib/*.so; do
  header="$(readelf -h "$elf")"
  if ! grep -q 'Machine:.*Advanced Micro Devices X86-64' <<< "$header"; then
    echo "Expected an x86_64 ELF: $elf" >&2
    exit 1
  fi
  linkage="$(ldd "$elf" 2>&1)"
  if grep -Eq "libgtk-$other_gtk\\.so|not found" <<< "$linkage"; then
    echo "GTK$other_gtk or unresolved dependency in $elf:" >&2
    echo "$linkage" >&2
    exit 1
  fi
  if [[ "$elf" == "$binary" ]] && ! grep -Fq "libgtk-$gtk.so" <<< "$linkage"; then
    echo "Browser does not link GTK$gtk" >&2
    exit 1
  fi
done
symbols="$(nm -D --defined-only "$bundle/lib/librust_lib_flutter_servo.so")"
if ! grep -q ' flutter_servo_session_new$' <<< "$symbols"; then
  echo "Bundle is missing the native Servo renderer entry point" >&2
  exit 1
fi
echo "Verified GTK$gtk x86_64 release bundle: $bundle"
