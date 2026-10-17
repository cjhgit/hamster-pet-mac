#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
workdir="$(mktemp -d /private/tmp/hamster-metal-check.XXXXXX)"
trap 'rm -rf "$workdir"' EXIT
clang++ -std=c++17 -O2 -c scripts/ui-test-bridge.cpp -o "$workdir/engine.o"
swiftc -O -parse-as-library -swift-version 5 \
  -import-objc-header scripts/UITestBridge.h \
  hamster-mac/HamsterView.swift hamster-mac/Hamster3DScene.swift hamster-mac/HamsterDeformableModel.swift hamster-mac/HamsterMetalRenderer.swift hamster-mac/AppDelegate.swift \
  scripts/verify-metal.swift "$workdir/engine.o" -Xlinker -lc++ -framework CoreText \
  -module-cache-path "$workdir/modules" -o "$workdir/verify-metal"
"$workdir/verify-metal" "$@"
