#!/usr/bin/env bash
# Package the full app only. Missing resources are errors, never removed inputs.
set -euo pipefail
app=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$app"
input=${1:?Directory containing codex-device/simulator and node-device/simulator tar.gz artifacts}
derived=${ASHELL_DERIVED_DATA:-$app/.build/ipa-derived}
dist=$app/.build/unsigned
mkdir -p "$dist" "$app/.build/ipa-slices"
for product in codex node; do
  for platform in device simulator; do
    mkdir -p "$app/.build/ipa-slices/$product/$platform"
    tar -xzf "$input/$product-$platform.tar.gz" -C "$app/.build/ipa-slices/$product/$platform"
  done
  target=$app/$product/$product.xcframework
  [[ $product != node ]] || target=$app/xcfs/node.xcframework
  if [[ -d $target ]]; then
    echo "Output already exists; use a fresh build checkout: $target" >&2
    exit 1
  fi
  xcodebuild -create-xcframework \
    -framework "$app/.build/ipa-slices/$product/device/device/$product.framework" \
    -framework "$app/.build/ipa-slices/$product/simulator/simulator/$product.framework" \
    -output "$target"
done
mkdir -p Resources/npm Resources/node-fetch
ditto -x -k "$input/node-npm.zip" Resources/npm
ditto -x -k "$input/node-fetch.zip" Resources/node-fetch
python3 gemini/build.py
swift package --package-path xcfs --jobs 4 resolve

# Use the exact ios_system ABI compiled with the AI command artifacts.
framework=xcfs/.build/artifacts/xcfs/ios_system/ios_system.xcframework
replacement=$app/.build/ipa-slices/ios_system.xcframework
xcodebuild -create-xcframework \
  -framework "$app/.build/ipa-slices/codex/device/device/ios_system.framework" \
  -framework "$app/.build/ipa-slices/codex/simulator/simulator/ios_system.framework" \
  -output "$replacement"
rsync -a --delete "$replacement/" "$framework/"

# The public Python download is 3.9; this project needs the maintainer's 3.13 set.
for required in Resources/Frameworks/Python.framework Resources/Library/lib/python3.13; do
  if [[ ! -e $required ]]; then
    echo "Full-app dependency missing: $required. Supply matching prebuilt dependencies; see README.md and a-Shell PR #1100." >&2
    exit 1
  fi
done
xcodebuild -project a-Shell.xcodeproj -scheme a-Shell -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived" -jobs 4 \
  ARCHS=arm64 IPHONEOS_DEPLOYMENT_TARGET=17.0 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build >"$dist/build.log" 2>&1 || {
    tail -n 80 "$dist/build.log" >&2; exit 1;
  }
bundle=$derived/Build/Products/Release-iphoneos/a-Shell.app
test -f "$bundle/Frameworks/codex.framework/codex"
test -f "$bundle/Frameworks/node.framework/node"
test -f "$bundle/gemini/launcher.mjs"
python3 "$app/ci/check-ai-minimum.py" "$bundle"
mkdir -p "$dist/Payload"
ditto "$bundle" "$dist/Payload/a-Shell.app"
(cd "$dist" && ditto -c -k --norsrc Payload a-Shell-ios17-unsigned.ipa)
shasum -a 256 "$dist/a-Shell-ios17-unsigned.ipa" >"$dist/SHA256SUMS"
unzip -tq "$dist/a-Shell-ios17-unsigned.ipa"
