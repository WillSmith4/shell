#!/usr/bin/env bash
set -euo pipefail
out="$PWD/.build/agy/iphonesimulator"
cd "$out"
ditto sdk/ios_system.framework Frameworks/ios_system.framework
codesign --force --sign - Frameworks/ios_system.framework
repo=$(git rev-parse --show-toplevel)
mkdir -p bin
touch bin/agy
chmod 755 bin/agy
python3 - "$repo" <<'PY'
import pathlib, plistlib, sys
cmd = plistlib.loads((pathlib.Path(sys.argv[1])/'Resources/commandDictionary.plist').read_bytes())['agy']
cmd[0] = str(pathlib.Path('Frameworks',cmd[0]).resolve())
pathlib.Path('commandDictionary.plist').write_bytes(plistlib.dumps({'agy':cmd}))
PY
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" -IFrameworks/ios_system.framework/Headers -FFrameworks -framework Foundation -framework ios_system -Wl,-rpath,@executable_path/Frameworks "$repo/agy/test-command.m" -o test-command
codesign --force --sign - test-command
device=$(xcrun simctl list devices available -j | python3 -c 'import sys,json; print(next(x["udid"] for k,v in json.load(sys.stdin)["devices"].items() if "iOS" in k for x in v if x["isAvailable"]))')
xcrun simctl boot "$device" || true
xcrun simctl bootstatus "$device" -b
python3 "$repo/agy/test_ui_gate.py" "$device" "$out" --command
