#!/usr/bin/env bash

prune_mobile_native_assets() {
  # The Android WebView dependency can emit JNI assets for Linux as well.
  # The desktop browser uses Servo and does not start a JVM.
  rm -f -- "$1/lib/libdartjni.so"
}

# Patch a copy so the original Flutter output stays intact.
stage_browser_bundle() {
  local source=$1 destination=$2 variant=$3 library
  mkdir -p "$destination"
  cp -a "$source/." "$destination/"
  prune_mobile_native_assets "$destination"
  # shellcheck disable=SC2016
  patchelf --set-rpath '$ORIGIN/lib' "$destination/flutter_servo_example"
  while IFS= read -r -d '' library; do
    # shellcheck disable=SC2016
    patchelf --set-rpath '$ORIGIN' "$library"
  done < <(find "$destination/lib" -maxdepth 1 -type f -name '*.so' -print0)
  bash "$(dirname "${BASH_SOURCE[0]}")/verify_linux_bundle.sh" "$destination" "$variant"
}

stage_browser_entries() {
  local variant=$1 installed_bundle=$2 launcher=$3 desktop=$4
  printf '#!/usr/bin/env sh\nexec %s/flutter_servo_example "$@"\n' "$installed_bundle" > "$launcher"
  chmod 755 "$launcher"
  printf '[Desktop Entry]\nType=Application\nName=Flutter Servo Browser (%s)\nComment=Browse the web with Servo\nExec=flutter-servo-browser-%s\nCategories=Network;WebBrowser;\nStartupNotify=true\nStartupWMClass=com.rnd.flutter_servo_browser\n' \
    "${variant^^}" "$variant" > "$desktop"
}
