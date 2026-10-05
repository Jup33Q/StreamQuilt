#!/bin/bash
# Build release binaries and wrap them in minimal .app bundles so macOS privacy
# permissions (microphone, automation) have an Info.plist to read.
#   .build/StreamQuilt-AI-Demo.app/Contents/MacOS/sq-ai-demo [args]
#   ".build/StreamQuilt.app/Contents/MacOS/streamquilt"
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=.build/StreamQuilt-AI-Demo.app
mkdir -p "$APP/Contents/MacOS"
cp .build/release/sq-ai-demo "$APP/Contents/MacOS/sq-ai-demo"
cp Sources/sq-ai-demo/Info.plist "$APP/Contents/Info.plist"

APPDIR=".build/StreamQuilt.app"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp .build/release/streamquilt "$APPDIR/Contents/MacOS/streamquilt"
cp Sources/StreamQuiltApp/Info.plist "$APPDIR/Contents/Info.plist"
cp assets/AppIcon.icns "$APPDIR/Contents/Resources/AppIcon.icns"

echo "built: $APP"
echo "run:   $APP/Contents/MacOS/sq-ai-demo"
echo "built: $APPDIR"
echo "run:   \"$APPDIR/Contents/MacOS/streamquilt\""
