#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_TMP="$(mktemp -d /private/tmp/qlab59-real.XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT
xcrun swiftc -module-cache-path /private/tmp/qlab59-real-cache -parse-as-library Sources/LiveMirror*.swift Sources/QLabOSCClient.swift Sources/RecoverySupport.swift Tests/RecoveryRealTests.swift -o "$TEST_TMP/tests"
QLAB_FALLBACK_TEST_LOG_STDOUT=1 "$TEST_TMP/tests"
