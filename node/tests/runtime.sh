#!/usr/bin/env bash
set -euo pipefail
simulator=${1:?Simulator UUID}
input=${2:?Node Simulator artifact tar.gz}
app=$(cd "$(dirname "$0")/../.." && pwd -P)
output=$app/.build/node-runtime
mkdir -p "$output/Frameworks" "$output/bin" "$output/deps"
tar -xzf "$input" -C "$output"
ditto "$output/simulator/node.framework" "$output/Frameworks/node.framework"
ditto "$output/simulator/ios_system.framework" "$output/Frameworks/ios_system.framework"
python3 - "$app" "$output" <<'PY'
import hashlib, json, pathlib, plistlib, re, shutil, sys, urllib.request, zipfile
app, output = map(pathlib.Path, sys.argv[1:])
manifest = (app / 'xcfs/Package.swift').read_text()
for product in ('text', 'shell'):
    url, checksum = re.search(r'name: "'+product+r'",\s+url: "([^"]+)",\s+checksum: "([^"]+)"', manifest).groups()
    archive = output / 'deps' / (product+'.zip')
    urllib.request.urlretrieve(url, archive)
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == checksum
    with zipfile.ZipFile(archive) as source:
        source.extractall(output / 'deps' / product)
    framework = next(p for p in (output/'deps'/product).rglob(product+'.framework') if 'simulator' in str(p) and 'arm64' in str(p))
    shutil.copytree(framework,output/'Frameworks'/framework.name,dirs_exist_ok=True)
commands = plistlib.loads((app/'Resources/commandDictionary.plist').read_bytes())
selected = {}
for command in ('node','dash','sleep','echo','cat','printf'):
    definition = commands.get(command)
    if definition:
        definition[0] = str(output/'Frameworks'/definition[0])
        selected[command] = definition
        (output/'bin'/command).touch()
        (output/'bin'/command).chmod(0o755)
with (output/'commandDictionary.plist').open('wb') as target:
    plistlib.dump(selected,target)
PY
bash "$app/ci/build-ai-dash.sh" simulator "$output/Frameworks" "$output/dash-build"
python3 "$app/gemini/build.py"
ditto "$app/Resources/gemini" "$output/gemini"
cp "$app/node/tests/wasm.cjs" "$output/"
cp "$app/gemini/tests/host.mjs" "$app/gemini/tests/files.mjs" "$app/gemini/tests/shell.mjs" "$output/"
# Host test default path is checkout-relative; point it at the harness bundle.
sed -i '' "s@Resources/gemini/@gemini/@" "$output/host.mjs"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator \
  -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -I "$output/Frameworks/ios_system.framework/Headers" -F "$output/Frameworks" \
  -framework Foundation -framework ios_system -Wl,-rpath,"$output/Frameworks" \
  "$app/node/tests/runtime.m" -o "$output/runtime"
if [[ ${ASHELL_NATIVE_DEBUG:-0} == 1 ]]; then
  xcrun simctl spawn --wait-for-debugger "$simulator" "$output/runtime" "$output" >"$output/runtime-launch.txt" 2>&1 &
  launcher=$!
  for i in {1..100}; do
    pid=$(pgrep -n -f "^$output/runtime" || true)
    [[ -z $pid ]] || break
    sleep 0.2
  done
  [[ -n $pid ]] || { cat "$output/runtime-launch.txt"; exit 1; }
  xcrun lldb --batch -p "$pid" -o continue -k 'thread backtrace all' \
    -k 'register read pc sp fp' -k 'image list -o -f' -k 'disassemble --pc --count 12' \
    -k 'process kill' >"$output/runtime-debugger.txt" 2>&1
  wait "$launcher" || true
  cat "$output/runtime-debugger.txt"
  exit 1
fi
if ! xcrun simctl spawn "$simulator" "$output/runtime" "$output" 2>"$output/runtime-native.txt"; then
  tail -n 100 "$output/runtime-native.txt"
  # Separate startup failure from same-process reuse of an earlier WASM isolate.
  SIMCTL_CHILD_ASHELL_GEMINI_FIRST=1 xcrun simctl spawn "$simulator" "$output/runtime" "$output" \
    >"$output/runtime-fresh-stdout.txt" 2>"$output/runtime-fresh-native.txt" || true
  # The embedding adapter captures JS stderr, but V8 fatal errors can go to
  # process stderr or a Darwin crash report. Keep both for native diagnosis.
  sleep 5
  mkdir -p "$output/crashes"
  find "$HOME/Library/Logs/DiagnosticReports" -name 'runtime*.ips' -exec cp {} "$output/crashes/" \; 2>/dev/null || true
  xcrun simctl spawn "$simulator" log show --last 3m --style compact \
    --predicate 'process == "runtime"' >"$output/runtime-system.txt" 2>&1 || true
  exit 1
fi
