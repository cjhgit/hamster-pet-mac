#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
workdir="$PWD/.build/verification/playback"
mkdir -p "$workdir"
engine_object="$workdir/engine.o"
clang++ -std=c++17 -O2 -c scripts/ui-test-bridge.cpp -o "$engine_object"
swiftc -parse-as-library -swift-version 5 \
  -import-objc-header scripts/UITestBridge.h \
  hamster-mac/HamsterView.swift hamster-mac/Hamster3DScene.swift hamster-mac/HamsterDeformableModel.swift hamster-mac/HamsterMetalRenderer.swift \
  hamster-mac/AppDelegate.swift scripts/verify-playback.swift "$engine_object" \
  -Xlinker -lc++ -framework CoreText \
  -module-cache-path "$workdir/modules" -o "$workdir/verify-playback"
"$workdir/verify-playback" "$@"
