#!/usr/bin/env bash
set -euo pipefail

# Adapted from rnd_pcalc_ng_public's prebuilt GTK4 engine installer.
flutter_root="${1:?Usage: $0 /path/to/flutter-sdk}"
engine_version="${FLUTTER_PREBUILT_ENGINE_VERSION:?Set FLUTTER_PREBUILT_ENGINE_VERSION}"
storage_base_url="${FLUTTER_STORAGE_BASE_URL:-${FLUTTER_ENGINE_STORAGE_BASE_URL:-}}"
: "${storage_base_url:?Set FLUTTER_STORAGE_BASE_URL}"
engine_root="$flutter_root/bin/cache/artifacts/engine"
archive_base="${storage_base_url%/}/flutter_infra_release/flutter/$engine_version"

verify_engine_bundle() {
  local destination="$1" mode="$2" required_file linkage
  for required_file in LICENSE.flutter_gtk.md flutter_linux/flutter_linux.h \
    gen_snapshot libflutter_linux_gtk.so libflutter_linux_gtk4.so; do
    if [[ ! -f "$destination/$required_file" ]]; then
      echo "Published $mode engine is missing $required_file" >&2
      return 1
    fi
  done
  test -x "$destination/gen_snapshot"
  linkage="$(readelf -d "$destination/libflutter_linux_gtk.so")"
  grep -q 'Shared library: \[libgtk-3.so' <<< "$linkage"
  linkage="$(readelf -d "$destination/libflutter_linux_gtk4.so")"
  grep -q 'Shared library: \[libgtk-4.so' <<< "$linkage"
  if grep -q 'Shared library: \[libgtk-3.so' <<< "$linkage"; then
    echo "Published $mode GTK4 engine also links GTK3" >&2
    return 1
  fi
}

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/servo-gtk4-engines.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
for cache_mode in linux-x64 linux-x64-profile linux-x64-release; do
  archive_mode="$cache_mode"
  if [[ "$cache_mode" == linux-x64 ]]; then archive_mode=linux-x64-debug; fi
  archive_file="$staging_dir/$archive_mode.zip"
  destination="$staging_dir/$cache_mode"
  mkdir -p "$destination"
  curl --fail --location --retry 3 --retry-all-errors --silent --show-error \
    "$archive_base/$archive_mode/linux-x64-flutter-gtk.zip" -o "$archive_file"
  unzip -tq "$archive_file"
  unzip -q "$archive_file" -d "$destination"
  verify_engine_bundle "$destination" "$archive_mode"
done

# Validate all modes before replacing the SDK cache.
for cache_mode in linux-x64 linux-x64-profile linux-x64-release; do
  mkdir -p "$engine_root/$cache_mode"
  cp -a "$staging_dir/$cache_mode/." "$engine_root/$cache_mode/"
done
