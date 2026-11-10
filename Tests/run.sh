#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
swiftc -parse-as-library Sources/ReadOnlyFS.swift Sources/PathInput.swift Sources/Mailbox.swift Sources/NewBinDiff.swift Sources/LockedBins.swift Sources/UpdateShared.swift Sources/UpdateLogic.swift Sources/BugReport.swift Sources/Updater/Installer.swift Tests/CoreTests.swift Tests/UpdateTests.swift -o "$OUT/tests"
"$OUT/tests" "$OUT"
rm -rf "$OUT"
