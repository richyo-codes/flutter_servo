#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
library="${1:?Usage: bash tools/run_windowproxy_stress.sh PATH_TO_RUST_LIBRARY}"
logs="${LOG_DIR:-$root/logs/windowproxy-$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$logs"
export RUST_BACKTRACE=full

# Compile the probe once and establish that the basic session works.
timeout 60s bash "$root/tools/run_native_session_probe.sh" "$library" > "$logs/baseline.log" 2>&1
probe="$root/.dart_tool/native_session_probe/native_session_probe"
failed=0
for delay in 0 5 100; do
  for attempt in 1 2 3; do
    log="$logs/navigation-${delay}-${attempt}.log"
    status=0
    timeout 20s "$probe" --html-file "$root/tools/fixtures/iframe_navigation_stress.html" \
      --close-loading --observe-ms 1000 --navigate-after-ms "$delay" "$library" \
      > "$log" 2>&1 || status=$?
    # A child script-thread panic does not necessarily change the process exit
    # status or reach WebViewDelegate::notify_crashed.
    if [[ "$status" -ne 0 ]] || grep -Eq 'panicked at|assertion failed|Servo page crashed|reported a page crash' "$log"; then
      printf 'FAIL delay=%s attempt=%s exit=%s log=%s\n' "$delay" "$attempt" "$status" "$log"
      failed=1
    else
      printf 'PASS delay=%s attempt=%s\n' "$delay" "$attempt"
    fi
  done
done
printf 'Backtrace logs: %s\n' "$logs"
exit "$failed"
