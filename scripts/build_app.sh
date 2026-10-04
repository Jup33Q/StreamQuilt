#!/bin/bash
# Build release binaries and wrap them in minimal .app bundles so macOS privacy
# permissions (microphone, automation) have an Info.plist to read.
#   .build/LKG-AI-Demo.app/Contents/MacOS/lkg-ai-demo [args]
#   ".build/LKG Studio.app/Contents/MacOS/lkg-studio"
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=.build/LKG-AI-Demo.app
mkdir -p "$APP/Contents/MacOS"
cp .build/release/lkg-ai-demo "$APP/Contents/MacOS/lkg-ai-demo"
cp Sources/lkg-ai-demo/Info.plist "$APP/Contents/Info.plist"

STUDIO=".build/LKG Studio.app"
mkdir -p "$STUDIO/Contents/MacOS"
cp .build/release/lkg-studio "$STUDIO/Contents/MacOS/lkg-studio"
cp Sources/lkg-studio/Info.plist "$STUDIO/Contents/Info.plist"

echo "built: $APP"
echo "run:   $APP/Contents/MacOS/lkg-ai-demo"
echo "built: $STUDIO"
echo "run:   \"$STUDIO/Contents/MacOS/lkg-studio\""
