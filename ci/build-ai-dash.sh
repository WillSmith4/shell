#!/usr/bin/env bash
# Codex's prerequisite Dash fixes, built for the current ios_system ABI.
set -euo pipefail
platform=${1:?device or simulator}
frameworks=${2:?Directory containing ios_system.framework}
work=${3:?New build directory}
case $platform in
  device) sdk=iphoneos; triple=arm64-apple-ios17.0 ;;
  simulator) sdk=iphonesimulator; triple=arm64-apple-ios17.0-simulator ;;
  *) exit 2 ;;
esac
mkdir -p "$work/source"
work=$(cd "$work" && pwd -P)
frameworks=$(cd "$frameworks" && pwd -P)
revision=c95f39a9ac177a8964b91cd7474e972884376b76
curl -fLsS --retry 3 "https://codeload.github.com/holzschu/dash_iOS/tar.gz/$revision" -o "$work/source.tar.gz"
echo "4977c6b7fb3ff075fc93aec272059355f9bb4b7e46591a2ce0ee2b9b810c0500  $work/source.tar.gz" | shasum -a 256 -c -
tar -xzf "$work/source.tar.gz" --strip-components=1 -C "$work/source"
sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
host_sdk=$(xcrun --sdk macosx --show-sdk-path)
(
  cd "$work/source"
  flags="-std=gnu17 -target $triple -isysroot $sdk_path -DJOBS=0 -Dstat64=stat -Dlstat64=lstat -Dfstat64=fstat -DUSE_GLIBC_STDIO=1 -DFLUSHERR=1 -I$PWD -I$frameworks/ios_system.framework/Headers"
  ./configure CC=clang CXX=clang++ CC_FOR_BUILD="clang -isysroot $host_sdk -DJOBS=0" \
    CFLAGS="$flags" CPPFLAGS="$flags" CXXFLAGS="$flags" \
    LDFLAGS="-target $triple -isysroot $sdk_path -dynamiclib -F $frameworks -framework ios_system" \
    --build=arm-apple-darwin --host=aarch64-apple-darwin cross_compiling=yes --with-libedit >"$work/configure.log" 2>&1
  make -j3 >"$work/make.log" 2>&1
) || { tail -n 60 "$work/configure.log" "$work/make.log" >&2; exit 1; }
for name in dash dashA dashB dashC dashD dashE; do
  output=$frameworks/$name.framework
  mkdir -p "$output"
  cp "$work/source/src/dash" "$output/$name"
  cp "$work/source/basic_Info.plist" "$output/Info.plist"
  cp "$work/source/COPYING" "$output/LICENSE"
  plutil -replace CFBundleExecutable -string "$name" "$output/Info.plist"
  plutil -replace CFBundleName -string "$name" "$output/Info.plist"
  plutil -replace CFBundleIdentifier -string "Nicolas-Holzschuch.$name" "$output/Info.plist"
  plutil -replace MinimumOSVersion -string 17.0 "$output/Info.plist"
  install_name_tool -id "@rpath/$name.framework/$name" "$output/$name"
done
