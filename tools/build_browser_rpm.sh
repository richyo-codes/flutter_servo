#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/tools/linux_browser_packaging.sh"
variant=gtk4
bundle_dir=""
output_dir=""
raw_version=""
license_id="${BROWSER_LICENSE:-LicenseRef-Unspecified}"

usage() {
  echo "Usage: $0 [--gtk gtk3|gtk4] [--bundle-dir PATH] [--out-dir PATH] [--version VERSION] [--license SPDX-ID]"
  echo "Package an existing x86_64 Linux release bundle (default: gtk4)."
}
while (( $# )); do
  case "$1" in
    --gtk|--bundle-dir|--out-dir|--version|--license)
      if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then
        echo "Missing value for $1" >&2; exit 2
      fi
      case "$1" in
        --gtk) variant="$2" ;;
        --bundle-dir) bundle_dir="$2" ;;
        --out-dir) output_dir="$2" ;;
        --version) raw_version="$2" ;;
        --license) license_id="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$variant" in
  gtk3) bundle_dir_default=linux ;;
  gtk4) bundle_dir_default=linux-gtk4 ;;
  *) echo "Invalid GTK variant: $variant" >&2; exit 2 ;;
esac
bundle_dir="${bundle_dir:-$repo_dir/packages/flutter_servo/example/build/$bundle_dir_default/x64/release/bundle}"
output_dir="${output_dir:-$repo_dir/build/packages/rpm/$variant}"
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo "RPM packaging requires an x86_64 Linux host" >&2; exit 1
fi
for command_name in rpmbuild rpm patchelf readelf nm ldd tar sha256sum; do
  command -v "$command_name" >/dev/null || {
    echo "Missing required command: $command_name" >&2; exit 1;
  }
done
if [[ ! "$license_id" =~ ^[A-Za-z0-9.+_-]+$ ]]; then
  echo "Expected one SPDX license identifier, got: $license_id" >&2; exit 2
fi
if [[ -z "$raw_version" ]]; then
  raw_version="$(git -C "$repo_dir" describe --tags --always --dirty)"
fi
raw_version="${raw_version#v}"
if [[ ! "$raw_version" =~ ^[A-Za-z0-9.+_~-]+$ ]]; then
  echo "Invalid artifact version: $raw_version" >&2; exit 2
fi
rpm_version=0.0.0
rpm_release="0.${raw_version//-/.}"
if [[ "$raw_version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-([0-9]+)-g([0-9a-f]+))?(-dirty)?$ ]]; then
  rpm_version="${BASH_REMATCH[1]}"
  rpm_release="${BASH_REMATCH[3]:-1}"
  if [[ -n "${BASH_REMATCH[4]:-}" ]]; then rpm_release+=".g${BASH_REMATCH[4]}"; fi
  if [[ -n "${BASH_REMATCH[5]:-}" ]]; then rpm_release+=.dirty; fi
elif [[ "$raw_version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([A-Za-z][A-Za-z0-9.+_-]*)$ ]]; then
  rpm_version="${BASH_REMATCH[1]}~${BASH_REMATCH[2]//-/.}"
  rpm_release=1
fi

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
bundle_dir="$(cd "$bundle_dir" && pwd)"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/servo-browser-rpm.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
mkdir -p "$staging_dir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
package_name=flutter-servo-browser-$variant
source_dir="$staging_dir/SOURCES/$package_name"
prepared_bundle="$source_dir/bundle"
stage_browser_bundle "$bundle_dir" "$prepared_bundle" "$variant"
stage_browser_entries "$variant" "/usr/lib64/$package_name" "$source_dir/launcher" "$source_dir/browser.desktop"
tar -C "$staging_dir/SOURCES" -czf "$staging_dir/SOURCES/$package_name.tar.gz" "$package_name"
sed -e "s/@VERSION@/$rpm_version/g" -e "s/@RELEASE@/$rpm_release/g" \
  -e "s/@LICENSE@/$license_id/g" -e "s/@GTK@/$variant/g" "$repo_dir/packaging/rpm/browser.spec.in" \
  > "$staging_dir/SPECS/$package_name.spec"
rpmbuild --define "_topdir $staging_dir" --define "_tmppath $staging_dir" \
  -bb "$staging_dir/SPECS/$package_name.spec"
mapfile -t packages < <(find "$staging_dir/RPMS" -type f -name '*.rpm')
if (( ${#packages[@]} != 1 )); then
  echo "Expected exactly one browser RPM" >&2; exit 1
fi
artifact="$output_dir/flutter-servo-browser-linux-x86_64-$variant-$raw_version.rpm"
cp "${packages[0]}" "$artifact"
(
  cd "$output_dir"
  sha256sum "$(basename "$artifact")" > "$(basename "$artifact").sha256"
)
rpm -qp --requires "$artifact" > "$artifact.requires.txt"
echo "Built $artifact"
