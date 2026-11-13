#!/bin/zsh
# Xcode 本体なし（Command Line Tools のみ）の環境でも Swift Testing を動かす
set -e
cd "$(dirname "$0")/.."
DEV=$(xcode-select -p)
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"
if [[ -d "$FW/Testing.framework" ]]; then
  swift test -Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" "$@"
else
  swift test "$@"
fi
