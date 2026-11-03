#!/usr/bin/env bash
# Reproducible native AI command slices for the unsigned iOS application.
set -euo pipefail
app=$(cd "$(dirname "$0")/.." && pwd -P)
product=${1:?codex or node}
platform=${2:?device or simulator}
case $product in codex|node) ;; *) exit 2 ;; esac
case $platform in device|simulator) ;; *) exit 2 ;; esac
work=$app/.build/ai/$product-$platform
mkdir -p "$work" "$app/.build/dist"
revision=df998e76cea0266bd3615bb9a1f4f7d745f318a2
checksum=6d2201c1dee131b831b8108b578ede560277d1c205fd8c64f2fb9dcd70e7baca
if [[ ! -f $work/ios-system.tar.gz ]]; then
  curl -fLsS --retry 3 "https://codeload.github.com/holzschu/ios_system/tar.gz/$revision" -o "$work/ios-system.tar.gz"
fi
echo "$checksum  $work/ios-system.tar.gz" | shasum -a 256 -c -
if [[ ! -d $work/ios-system ]]; then
  mkdir "$work/ios-system"
  tar -xzf "$work/ios-system.tar.gz" --strip-components=1 -C "$work/ios-system"
fi
sdk=iphoneos
[[ $platform != simulator ]] || sdk=iphonesimulator
xcodebuild -project "$work/ios-system/ios_system.xcodeproj" -target ios_system \
  -configuration Release -sdk "$sdk" -jobs 3 ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  IPHONEOS_DEPLOYMENT_TARGET=16.0 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CONFIGURATION_BUILD_DIR="$work/sdk" build >"$work/sdk.log" 2>&1 || {
    tail -n 80 "$work/sdk.log"; exit 1;
  }
if [[ $product == codex ]]; then
  export CODEX_BUILD_CACHE=$work/codex CARGO_BUILD_JOBS=3
  bash "$app/codex/build.sh" framework "$work/sdk" "$platform"
  framework=$CODEX_BUILD_CACHE/$platform/codex.framework
else
  export NODE_IOS_CACHE=$work/node NODE_IOS_PLATFORMS=$platform NODE_IOS_JOBS=3
  export IOS_SYSTEM_XCFRAMEWORK=$work/ios_system.xcframework
  export NODE_IOS_XCFRAMEWORK=$work/node.xcframework
  if [[ ! -d $IOS_SYSTEM_XCFRAMEWORK ]]; then
    xcodebuild -create-xcframework -framework "$work/sdk/ios_system.framework" -output "$IOS_SYSTEM_XCFRAMEWORK"
  fi
  stage=device
  [[ $platform != simulator ]] || stage=node
  if [[ ${ASHELL_NODE_PACKAGE_ONLY:-0} != 1 ]]; then
    bash "$app/node/build.sh" "$stage"
  fi
  bash "$app/node/build.sh" package
  cp "$NODE_IOS_CACHE/node-$platform.map" "$app/.build/dist/node-$platform.map"
  framework=$NODE_IOS_CACHE/framework/$platform/node.framework
  if [[ $platform == device ]]; then
    ditto -c -k --norsrc "$app/Resources/npm" "$app/.build/dist/node-npm.zip"
    ditto -c -k --norsrc "$app/Resources/node-fetch" "$app/.build/dist/node-fetch.zip"
  fi
fi
xcrun vtool -show-build "$framework/$product"
mkdir -p "$work/package/$platform"
ditto "$framework" "$work/package/$platform/$product.framework"
ditto "$work/sdk/ios_system.framework" "$work/package/$platform/ios_system.framework"
tar -czf "$app/.build/dist/$product-$platform.tar.gz" -C "$work/package" "$platform"
