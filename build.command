#!/bin/zsh
set -eu
cd -- "${0:A:h}"
APP="$PWD/FrameFloat.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PWD/.build-cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -module-cache-path "$PWD/.build-cache" \
  -framework AppKit -framework QuartzCore Sources/main.swift \
  -o "$APP/Contents/MacOS/FrameFloat"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
print "Built: $APP"
