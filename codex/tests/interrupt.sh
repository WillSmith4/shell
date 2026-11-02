#!/usr/bin/env bash
set -euo pipefail
simulator=${1:?Simulator UUID}
frameworks=${2:?Directory holding Codex and ios_system Simulator frameworks}
output=${3:?New disposable test directory}
here=$(cd "$(dirname "$0")" && pwd -P)
mkdir "$output"
output=$(cd "$output" && pwd -P)
mkdir -p "$output/home" "$output/bin"
touch "$output/bin/codex"
chmod +x "$output/bin/codex"
python3 - "$output" "$frameworks" <<'PY'
import pathlib, plistlib, sys
root, frameworks = map(pathlib.Path, sys.argv[1:])
with (root / 'commandDictionary.plist').open('wb') as target:
    plistlib.dump({'codex': [str(frameworks / 'codex.framework/codex'), 'codex_ios_main', '', 'file']}, target)
PY
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator \
  -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -I "$frameworks/ios_system.framework/Headers" -F "$frameworks" \
  -framework Foundation -framework ios_system -Wl,-rpath,"$frameworks" \
  "$here/interrupt.m" -o "$output/interrupt"
python3 "$here/interrupt-server.py" "$output" &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
for i in {1..100}; do
  [[ ! -f $output/server-ready ]] || break
  sleep 0.1
done
test -f "$output/server-ready"
xcrun simctl spawn "$simulator" "$output/interrupt" "$output"
