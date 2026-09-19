#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_TMP="$(mktemp -d /private/tmp/qlab-performance.XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT
cat Sources/NetworkDiscovery.swift Tests/ManagerTestAccess.swift > "$TEST_TMP/NetworkDiscovery.swift"
SOURCES=()
for SOURCE in Sources/*.swift; do
  case "$SOURCE" in *ContentView.swift|*AdvancedSettingsHost.swift|*App.swift|*NetworkDiscovery.swift) ;; *) SOURCES+=("$SOURCE");; esac
done
xcrun swiftc -module-cache-path /private/tmp/qlab-review-cache -parse-as-library "${SOURCES[@]}" "$TEST_TMP/NetworkDiscovery.swift" Tests/PerformanceTests.swift -framework Security -o "$TEST_TMP/tests"
QLAB_FALLBACK_TEST_LOG_STDOUT=1 "$TEST_TMP/tests" "$@"
