#!/usr/bin/env bash
set -euo pipefail
simulator=${1:?Simulator UUID}
input=${2:?Node Simulator artifact tar.gz}
npm=${3:?Bundled npm artifact zip}
app=$(cd "$(dirname "$0")/../.." && pwd -P)
output=$app/.build/node-runtime
mkdir -p "$output/Frameworks" "$output/bin" "$output/deps"
tar -xzf "$input" -C "$output"
ditto "$output/simulator/node.framework" "$output/Frameworks/node.framework"
ditto "$output/simulator/ios_system.framework" "$output/Frameworks/ios_system.framework"
ditto -x -k "$npm" "$output/npm"
# Use the actual packaged command files: synthesizing placeholders hid missing
# bin/node, bin/npm and bin/npx in the full app.
ditto "$app/Resources/bin" "$output/bin"
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
for command in ('node','npm','npx','sh','dash','sleep','echo','cat','printf','dirname','sed','uname'):
    definition = commands.get(command)
    if definition:
        definition[0] = str(output/'Frameworks'/definition[0])
        selected[command] = definition
with (output/'commandDictionary.plist').open('wb') as target:
    plistlib.dump(selected,target)
for command in ('node','npm','npx','dash'):
    marker = output/'bin'/command
    assert marker.is_file() and marker.stat().st_size == 0, f'Missing native command marker: {command}'
# An offline JS CLI exercises npx's actual shell -> shim -> Node execution path.
fixture = output/'node_modules'/'ashell-npx-check'
fixture.mkdir(parents=True, exist_ok=True)
(fixture/'package.json').write_text(json.dumps({'name':'ashell-npx-check', 'version':'1.0.0', 'bin':{'ashell-npx-check':'cli.cjs'}}))
(fixture/'cli.cjs').write_text('#!/usr/bin/env node\nrequire("fs").writeFileSync("npx-result.txt", "NPX_OK"); console.log("NPX_OK");\n')
(output/'package.json').write_text(json.dumps({'name':'ashell-runtime-check', 'version':'1.0.0', 'scripts':{'check':'node node_modules/ashell-npx-check/cli.cjs'}}))
PY
bash "$app/ci/build-ai-dash.sh" simulator "$output/Frameworks" "$output/dash-build"
python3 "$app/gemini/build.py"
ditto "$app/Resources/gemini" "$output/gemini"
cp "$app/node/tests/wasm.cjs" "$output/"
cp "$app/node/tests/intl.cjs" "$output/"
cp "$app/node/tests/missing-command.cjs" "$output/"
cp "$app/gemini/tests/host.mjs" "$app/gemini/tests/files.mjs" "$app/gemini/tests/shell.mjs" "$output/"
# Host test default path is checkout-relative; point it at the harness bundle.
sed -i '' "s@Resources/gemini/@gemini/@" "$output/host.mjs"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator \
  -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -I "$output/Frameworks/ios_system.framework/Headers" -F "$output/Frameworks" \
  -framework Foundation -framework ios_system -Wl,-rpath,"$output/Frameworks" \
  "$app/node/tests/runtime.m" -o "$output/runtime"
if [[ ${ASHELL_NATIVE_DEBUG:-0} == 1 ]]; then
  SIMCTL_CHILD_ASHELL_INTERACTIVE_ONLY=1 xcrun simctl spawn --wait-for-debugger "$simulator" "$output/runtime" "$output" >"$output/runtime-launch.txt" 2>&1 &
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
SIMCTL_CHILD_ASHELL_INTERACTIVE_ONLY=1 xcrun simctl spawn "$simulator" "$output/runtime" "$output" \
  >"$output/runtime-interactive-launch.txt" 2>"$output/runtime-interactive-native.txt"
cp "$output/runtime-output.txt" "$output/runtime-interactive-output.txt"
cp "$output/runtime-errors.txt" "$output/runtime-interactive-errors.txt"
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
