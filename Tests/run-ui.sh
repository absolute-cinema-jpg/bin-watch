#!/bin/bash
# Clicks and types through the browser (offscreen) and checks selection & navigation.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
swiftc -parse-as-library $(ls Sources/*.swift | grep -v BinWatchApp.swift) Tests/UI/*.swift -o "$OUT/ui-tests" 2>&1 | grep -v warning || true
"$OUT/ui-tests" "$OUT" 2>&1 | grep -v WARNING
rm -rf "$OUT"
