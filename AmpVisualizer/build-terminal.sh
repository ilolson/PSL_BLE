#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/terminal-module-cache
xcrun swiftc -O -swift-version 5 -module-cache-path build/terminal-module-cache Terminal/main.swift -o build/amp-lights -framework CoreBluetooth -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Terminal/Info.plist
codesign --force --sign - build/amp-lights
echo "Built: $PWD/build/amp-lights"
