#!/bin/bash
# Build lkg-ai-demo and wrap it in a minimal .app bundle so macOS privacy
# permissions (microphone, automation) have an Info.plist to read.
# Run the result via:  .build/LKG-AI-Demo.app/Contents/MacOS/lkg-ai-demo [args]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=.build/LKG-AI-Demo.app
mkdir -p "$APP/Contents/MacOS"
cp .build/release/lkg-ai-demo "$APP/Contents/MacOS/lkg-ai-demo"
cp Sources/lkg-ai-demo/Info.plist "$APP/Contents/Info.plist"

echo "built: $APP"
echo "run:   $APP/Contents/MacOS/lkg-ai-demo"
