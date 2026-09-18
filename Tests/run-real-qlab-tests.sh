#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_TMP="$(mktemp -d /private/tmp/qlab55-real.XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT
cat Sources/NetworkDiscovery.swift Tests/ManagerTestAccess.swift > "$TEST_TMP/NetworkDiscovery.swift"
SOURCES=()
for SOURCE in Sources/*.swift; do
  case "$SOURCE" in *ContentView.swift|*App.swift|*NetworkDiscovery.swift) ;; *) SOURCES+=("$SOURCE");; esac
done
xcrun swiftc -module-cache-path /private/tmp/qlab55-test-cache -parse-as-library "${SOURCES[@]}" "$TEST_TMP/NetworkDiscovery.swift" Tests/RealQLabTests.swift -framework Security -o "$TEST_TMP/tests"
"$TEST_TMP/tests"
