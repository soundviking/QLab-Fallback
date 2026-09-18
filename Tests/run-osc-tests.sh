#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Validation
TEST_TMP="$(mktemp -d /private/tmp/qlab55-osc.XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT
cat Sources/NetworkDiscovery.swift Tests/ManagerTestAccess.swift > "$TEST_TMP/NetworkDiscovery.swift"
cat Sources/QLabOSCClient.swift > "$TEST_TMP/QLabOSCClient.swift"
cat >> "$TEST_TMP/QLabOSCClient.swift" <<'SWIFT'
extension QLabOSCClient {
    func testReceiverCount() -> Int { queue.sync { receiverConnections.count } }
}
SWIFT
SOURCES=()
for SOURCE in Sources/*.swift; do
  case "$SOURCE" in *ContentView.swift|*App.swift|*NetworkDiscovery.swift|*QLabOSCClient.swift) ;; *) SOURCES+=("$SOURCE");; esac
done
xcrun swiftc -module-cache-path /private/tmp/qlab55-test-cache -parse-as-library "${SOURCES[@]}" "$TEST_TMP/NetworkDiscovery.swift" "$TEST_TMP/QLabOSCClient.swift" Tests/OSCRecoveryTests.swift -framework Security -o "$TEST_TMP/tests"
QLAB_FALLBACK_TEST_LOG_STDOUT=1 "$TEST_TMP/tests"
