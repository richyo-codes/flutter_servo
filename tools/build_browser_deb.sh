#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/tools/linux_browser_packaging.sh"
variant=gtk4
bundle_dir=""
output_dir=""
raw_version=""
while (( $# )); do
  case "$1" in
    --gtk|--bundle-dir|--out-dir|--version)
      if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then
        echo "Missing value for $1" >&2; exit 2
      fi
      case "$1" in
        --gtk) variant="$2" ;;
        --bundle-dir) bundle_dir="$2" ;;
        --out-dir) output_dir="$2" ;;
        --version) raw_version="$2" ;;
      esac
      shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--gtk gtk3|gtk4] [--bundle-dir PATH] [--out-dir PATH] [--version VERSION]"
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$variant" in
  gtk3) build_dir=linux; gtk_dependency=libgtk-3-0 ;;
  gtk4) build_dir=linux-gtk4; gtk_dependency=libgtk-4-1 ;;
  *) echo "Invalid GTK variant: $variant" >&2; exit 2 ;;
esac
case "$(uname -m)" in
  x86_64) machine=x86_64; flutter_arch=x64; deb_arch=amd64 ;;
  aarch64) machine=aarch64; flutter_arch=arm64; deb_arch=arm64 ;;
  *) echo "Unsupported packaging architecture" >&2; exit 1 ;;
esac
if [[ "$(uname -s)" != Linux ]]; then
  echo "DEB packaging requires a Linux host" >&2; exit 1
fi
for command_name in dpkg-deb dpkg-shlibdeps patchelf readelf nm ldd sha256sum; do
  command -v "$command_name" >/dev/null || {
    echo "Missing required command: $command_name" >&2; exit 1;
  }
done

raw_version="${raw_version:-$(git -C "$repo_dir" describe --tags --always --dirty)}"
raw_version="${raw_version#v}"
if [[ ! "$raw_version" =~ ^[A-Za-z0-9.+_~-]+$ ]]; then
  echo "Invalid artifact version: $raw_version" >&2; exit 2
fi
version="0.0.0+git.${raw_version//_/.}"
if [[ "$raw_version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-([0-9]+-g[0-9a-f]+))?(-dirty)?$ ]]; then
  version="${BASH_REMATCH[1]}"
  if [[ -n "${BASH_REMATCH[3]}" ]]; then version+="+git.${BASH_REMATCH[3]}"; fi
  if [[ -n "${BASH_REMATCH[4]}" ]]; then version+="+dirty"; fi
elif [[ "$raw_version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([A-Za-z][A-Za-z0-9.+_-]*)$ ]]; then
  version="${BASH_REMATCH[1]}~${BASH_REMATCH[2]//_/.}"
fi

bundle_dir="${bundle_dir:-$repo_dir/packages/flutter_servo/example/build/$build_dir/$flutter_arch/release/bundle}"
output_dir="${output_dir:-$repo_dir/build/packages/deb/$variant}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
staging="$(mktemp -d "${TMPDIR:-/tmp}/servo-browser-deb.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
package=flutter-servo-browser-$variant
root="$staging/root"
installed_bundle="/usr/lib/$package"
bundle="$root$installed_bundle"
mkdir -p "$root"/{DEBIAN,usr/bin,usr/share/applications} "$staging/debian"
stage_browser_bundle "$bundle_dir" "$bundle" "$variant"
stage_browser_entries "$variant" "$installed_bundle" "$root/usr/bin/$package" \
  "$root/usr/share/applications/ca.richyoung.flutter_servo_browser.$variant.desktop"

printf 'Source: %s\n\nPackage: %s\nArchitecture: %s\nDescription: Flutter Servo Browser\n' \
  "$package" "$package" "$deb_arch" > "$staging/debian/control"
elf_args=("$bundle/flutter_servo_example" "$bundle"/lib/*.so)
# The embedded Flutter and Servo libraries are private and have no Debian shlibs records.
shlibs="$(cd "$staging" && dpkg-shlibdeps -O --ignore-missing-info -l"$bundle/lib" "${elf_args[@]}")"
depends="${shlibs#shlibs:Depends=}"
if [[ "$shlibs" != shlibs:Depends=* || "$depends" != *"$gtk_dependency"* ]]; then
  echo "Missing GTK dependencies. Build the DEB on Debian or Ubuntu with the runtime packages installed." >&2
  exit 1
fi
# Surfman opens EGL dynamically, so ELF dependency scanning may miss it.
if [[ "$depends" != *libegl1* ]]; then depends="libegl1, $depends"; fi
printf 'Package: %s\nVersion: %s\nSection: web\nPriority: optional\nArchitecture: %s\nMaintainer: Rich Young <code@richyoung.ca>\nDepends: %s\nDescription: Flutter browser powered by Servo using %s\n' \
  "$package" "$version" "$deb_arch" "$depends" "${variant^^}" > "$root/DEBIAN/control"
artifact="flutter-servo-browser-linux-$machine-$variant-$raw_version.deb"
dpkg-deb --root-owner-group --build "$root" "$output_dir/$artifact"
(cd "$output_dir" && sha256sum "$artifact" > "$artifact.sha256")
echo "Built $output_dir/$artifact"
