#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
swiftc -parse-as-library Sources/ReadOnlyFS.swift Sources/PathInput.swift Sources/Mailbox.swift Sources/NewBinDiff.swift Sources/LockedBins.swift Sources/AppLocation.swift Sources/UpdateShared.swift Sources/UpdateLogic.swift Sources/BugReportConfig.swift Sources/BugReport.swift Sources/Updater/Installer.swift Tests/CoreTests.swift Tests/UpdateTests.swift -o "$OUT/tests"
"$OUT/tests" "$OUT"
# Feedback links (bug reports and feature requests), from the github-bug-reports skill.
swiftc -parse-as-library Sources/BugReportConfig.swift Sources/BugReport.swift Tests/BugReportTests.swift -o "$OUT/feedback-tests"
"$OUT/feedback-tests"
rm -rf "$OUT"
