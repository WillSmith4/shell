#!/usr/bin/env bash
# Fast SDK syntax checks before the much longer Rust/V8 archive builds finish.
set -euo pipefail
app=$(cd "$(dirname "$0")/.." && pwd -P)
work=$app/.build/adapter-check
mkdir -p "$work/node" "$work/ios-system"
curl -fLsS --retry 3 https://nodejs.org/dist/v26.12.1/node-v26.12.1.tar.gz -o "$work/node.tar.gz"
echo "717244a8d757672ec86aae5077fca31e50f84b094441ec51bdf397aab12c304e  $work/node.tar.gz" | shasum -a 256 -c -
tar -xzf "$work/node.tar.gz" --strip-components=1 -C "$work/node"
curl -fLsS --retry 3 https://codeload.github.com/holzschu/ios_system/tar.gz/df998e76cea0266bd3615bb9a1f4f7d745f318a2 -o "$work/ios-system.tar.gz"
echo "6d2201c1dee131b831b8108b578ede560277d1c205fd8c64f2fb9dcd70e7baca  $work/ios-system.tar.gz" | shasum -a 256 -c -
tar -xzf "$work/ios-system.tar.gz" --strip-components=1 -C "$work/ios-system"
patch -s -N -F 0 -p1 -d "$work/node" <"$app/node/command-options.patch"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
common=(-target arm64-apple-ios17.0 -isysroot "$sdk" -fsyntax-only -Wall -Wextra -Werror -I "$work/ios-system/ios_system")
xcrun clang "${common[@]}" "$app/codex/command.m" "$app/codex/home.m"
xcrun clang "${common[@]}" -DASHELL_TOOL_TRANSPORT_ONLY "$app/codex/command.m"
for source in node-command.cc child-process.cc; do
  xcrun clang++ "${common[@]}" -x objective-c++ -std=c++20 -fmodules \
    -isystem "$work/node/src" -isystem "$work/node/deps/v8/include" -isystem "$work/node/deps/uv/include" \
    "$app/node/$source"
done
