#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
workdir="$(mktemp -d /private/tmp/hamster-native-snapshot.XXXXXX)"
trap 'rm -rf "$workdir"' EXIT
clang++ -std=c++17 -O2 -c scripts/ui-test-bridge.cpp -o "$workdir/engine.o"
swiftc -parse-as-library -swift-version 5 \
  -import-objc-header scripts/UITestBridge.h \
  hamster-mac/HamsterView.swift hamster-mac/AppDelegate.swift scripts/snapshot-native.swift "$workdir/engine.o" \
  -Xlinker -lc++ -framework CoreText \
  -module-cache-path "$workdir/modules" -o "$workdir/snapshot"
"$workdir/snapshot"
