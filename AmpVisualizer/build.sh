#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/module-cache 'build/Amp Visualizer.app/Contents/MacOS'
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path build/module-cache Sources/main.swift -o 'build/Amp Visualizer.app/Contents/MacOS/AmpVisualizer' -framework AppKit -framework Metal -framework QuartzCore -framework ScreenCaptureKit -framework CoreMedia -framework Accelerate
cp Info.plist 'build/Amp Visualizer.app/Contents/Info.plist'
codesign --force --sign - 'build/Amp Visualizer.app'
echo "Built: $PWD/build/Amp Visualizer.app"

./build-terminal.sh
