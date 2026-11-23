#!/usr/bin/env bash
set -euo pipefail
exec bash "$(dirname "${BASH_SOURCE[0]}")/verify_linux_bundle.sh" "${1:?Pass a release bundle}" gtk4
