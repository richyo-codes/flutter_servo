#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == --help || $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: bash $0 BROWSER_EXECUTABLE OUTPUT.png [HTTP_OR_HTTPS_URL]"
  [[ "${1:-}" == --help ]] && exit 0
  exit 2
fi

browser="$(realpath "$1")"
output="$(realpath -m "$2")"
url="${3:-}"
if [[ ! -x "$browser" || "$output" != *.png || ( -n "$url" && ! "$url" =~ ^https?://[^[:space:]/]+ ) ]]; then
  echo 'Expected an executable browser, a .png output path, and an HTTP(S) URL.' >&2
  exit 2
fi
for command in xvfb-run xdotool import timeout; do
  command -v "$command" >/dev/null || { echo "Missing capture dependency: $command" >&2; exit 1; }
done
histogram=convert
if [[ -z "$url" ]]; then
  if command -v magick >/dev/null; then histogram=magick; fi
  for command in python3 "$histogram"; do
    command -v "$command" >/dev/null || { echo "Missing rendering test dependency: $command" >&2; exit 1; }
  done
fi

mkdir -p "$(dirname "$output")"
work="$(mktemp -d)"
fixture="$(dirname "$(realpath "$0")")/fixtures"
trap 'rm -rf "$work"' EXIT
if ! timeout -k 5s 65s xvfb-run -a -s '-screen 0 1600x1000x24 -nolisten tcp' bash -s -- \
    "$browser" "$work" "$url" "$fixture" "$histogram" <<'CAPTURE'
set -euo pipefail
pid='' server=''
cleanup() {
  [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true
  [[ -z "$server" ]] || kill "$server" 2>/dev/null || true
  wait
}
trap cleanup EXIT

url="$3"
if [[ -z "$url" ]]; then
  python3 - "$4" "$2/port" <<'SERVER' &
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys

handler = partial(SimpleHTTPRequestHandler, directory=sys.argv[1])
with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
    Path(sys.argv[2]).write_text(str(server.server_port))
    server.serve_forever()
SERVER
  server=$!
  for ((i=0; i<40; i++)); do
    [[ -s "$2/port" ]] && break
    sleep .1
  done
  [[ -s "$2/port" ]] || { echo 'Fixture server did not start.' >&2; exit 1; }
  url="http://127.0.0.1:$(<"$2/port")/rendering.html"
  export NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}"
  export no_proxy="$NO_PROXY"
fi
export GDK_BACKEND=x11
export FLUTTER_SERVO_START_URL="$url"
export XDG_CONFIG_HOME="$2/config" XDG_CACHE_HOME="$2/cache" XDG_DATA_HOME="$2/data"
"$1" >"$2/browser.log" 2>&1 &
pid=$!

window=''
for ((i=0; i<120; i++)); do
  kill -0 "$pid" 2>/dev/null || exit 1
  windows="$(xdotool search --onlyvisible --pid "$pid" 2>/dev/null || true)"
  window="${windows%%$'\n'*}"
  [[ -n "$window" ]] && break
  sleep .25
done
[[ -n "$window" ]] || { echo 'Browser window did not appear.' >&2; exit 1; }
xdotool windowsize "$window" 1440 900

for ((i=0; i<120; i++)); do
  kill -0 "$pid" 2>/dev/null || exit 1
  if grep -q 'rust delegate load status Complete' "$2/browser.log"; then
    sleep 1
    # Never capture the root window or the user's desktop.
    import -window "$window" "$2/browser.png"
    if [[ -n "$3" ]] || "$5" "$2/browser.png" -depth 8 -format %c histogram:info:- |
        awk '
          $1 + 0 >= 1500 && /#F64B61/ { grid = 1 }
          $1 + 0 >= 1500 && /#24D7AE/ { flex = 1 }
          $1 + 0 >= 1500 && /#F6CC45/ { svg = 1 }
          END { exit !(grid && flex && svg) }
        '; then
      exit 0
    fi
  fi
  sleep .25
done
echo 'Servo did not finish loading or the expected rendering markers never appeared.' >&2
exit 1
CAPTURE
then
  test ! -f "$work/browser.log" || tail -n 30 "$work/browser.log" >&2
  exit 1
fi
install -m644 "$work/browser.png" "$output"
printf 'Saved browser window to %s\n' "$output"
