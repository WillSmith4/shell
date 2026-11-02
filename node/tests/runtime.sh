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
xcrun simctl spawn "$simulator" "$output/runtime" "$output"
