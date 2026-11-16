#!/usr/bin/env bash
set -euo pipefail
sdk=${1:?iphoneos or iphonesimulator}
binary=${2:?verified agy executable}
ios=${3:?directory containing ios_system.framework}
out=${4:?framework output directory}
target=arm64-apple-ios17.0
platform=2
supported=iPhoneOS
if [[ $sdk == iphonesimulator ]]; then
  target+=-simulator
  platform=7
  supported=iPhoneSimulator
elif [[ $sdk != iphoneos ]]; then exit 2; fi
clang=(xcrun --sdk "$sdk" clang -target "$target" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)")
for name in agy AgC AgCompat AgyEngine; do
  framework="$out/$name.framework"
  mkdir -p "$framework"
  python3 - "$framework/Info.plist" "$name" "$supported" <<'PY'
import plistlib, sys
path, name, platform = sys.argv[1:]
with open(path, 'wb') as f:
    plistlib.dump(dict(CFBundleExecutable=name, CFBundleName=name,
                       CFBundleIdentifier='com.ashell.port.'+name.lower(),
                       CFBundlePackageType='FMWK', CFBundleVersion='1',
                       CFBundleShortVersionString='1.5.9', MinimumOSVersion='17.0',
                       CFBundleSupportedPlatforms=[platform]), f)
PY
  link=(-dynamiclib -install_name "@rpath/$name.framework/$name" -o "$framework/$name")
  case $name in
    agy) "${clang[@]}" "${link[@]}" -fobjc-arc -I"$ios/ios_system.framework/Headers" -F"$ios" agy/command.m -framework Foundation -framework ios_system ;;
    AgC) "${clang[@]}" "${link[@]}" agy/probe_pipe_terminal.c agy/probe_ui_gate.c agy/app_exit.c -Wl,-reexport-lSystem ;;
    AgCompat) "${clang[@]}" "${link[@]}" agy/probe_compat.c -Wl,-reexport_framework,Security ;;
    AgyEngine) python3 agy/patch_probe.py --app --embedded --tui-gate --platform "$platform" "$binary" "$framework/$name" ;;
  esac
  codesign --force --sign - "$framework"
  codesign --verify --strict "$framework"
done
