#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
reference="${1:-../hamster-html}"
workdir="$(mktemp -d /private/tmp/hamster-native-check.XXXXXX)"
trap 'rm -rf "$workdir"' EXIT
clang++ -std=c++17 -O2 scripts/verify-native.cpp \
  -framework CoreGraphics -framework CoreText -framework CoreFoundation \
  -o "$workdir/verify"
"$workdir/verify"
node scripts/compare-native.cjs "$reference" "$workdir/verify"
