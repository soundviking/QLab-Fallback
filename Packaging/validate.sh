#!/bin/bash
# Reproducible checks; never replaces the reference PKG or installs an app.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="Artifacts/Review"
LOG="Validation/final"
CACHE="${TMPDIR:-/tmp}/qlab-review-validation-cache"
mkdir -p "$OUT" "$LOG"
for ARCH in arm64 x86_64; do
  xcrun swiftc -module-cache-path "$CACHE-$ARCH" -target "$ARCH-apple-macosx14.0" -parse-as-library Sources/*.swift -framework Security -o "$OUT/QLabFallback-$ARCH" > "$LOG/compile-$ARCH.log" 2>&1
done
xcrun swiftc -module-cache-path "$CACHE-tests" -parse-as-library Sources/LiveMirror*.swift Tests/LiveMirrorTests.swift -o "$OUT/integrity" > "$LOG/integrity-compile.log" 2>&1
"$OUT/integrity" > "$LOG/integrity.log" 2>&1
xcrun swiftc -module-cache-path "$CACHE-tests" -parse-as-library Sources/LiveMirror*.swift Sources/QLabOSCClient.swift Sources/WorkspaceTransferSupport.swift Sources/RecoverySupport.swift Tests/RegressionTests.swift -o "$OUT/regression" > "$LOG/regression-compile.log" 2>&1
"$OUT/regression" > "$LOG/regression.log" 2>&1
xcrun swiftc -module-cache-path "$CACHE-tests" -parse-as-library Sources/LiveMirror*.swift Tests/WorkspaceSignatureTests.swift -o "$OUT/signature" > "$LOG/signature-compile.log" 2>&1
python3 Tests/workspace-signature-tests.py "$OUT/signature" > "$LOG/signature.log" 2>&1
xcrun swiftc -module-cache-path "$CACHE-tests" -parse-as-library Sources/LiveMirror*.swift Sources/ResponsivenessPolicy.swift Sources/WorkspaceBinaryTransfer.swift Tests/BinaryTransferTests.swift -o "$OUT/binary" > "$LOG/binary-compile.log" 2>&1
"$OUT/binary" > "$LOG/binary.log" 2>&1
bash Tests/run-osc-tests.sh > "$LOG/osc.log" 2>&1
xcrun swiftc -module-cache-path "$CACHE-tests" -parse-as-library Sources/LiveMirror*.swift Sources/QLabDiscoveryService.swift Tests/DiscoveryTests.swift -o "$OUT/discovery" > "$LOG/discovery-compile.log" 2>&1
"$OUT/discovery" > "$LOG/discovery.log" 2>&1
xcrun swiftc -module-cache-path "$CACHE-tests" -parse-as-library Sources/BackupFolderStore.swift Tests/BackupFolderTests.swift -o "$OUT/folder" > "$LOG/folder-compile.log" 2>&1
"$OUT/folder" > "$LOG/folder.log" 2>&1
mkdir -p "$OUT/Localization"
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$OUT/Localization" > "$LOG/catalog.log" 2>&1
xcrun swiftc -module-cache-path "$CACHE-tests" -parse-as-library Sources/Localization.swift Tests/LocalizationTests.swift -o "$OUT/localization-tests" > "$LOG/localization-compile.log" 2>&1
"$OUT/localization-tests" "$PWD/$OUT/Localization" > "$LOG/localization.log" 2>&1
bash Tests/run-performance-tests.sh > "$LOG/performance.log" 2>&1
python3 Packaging/check-scripts.py > "$LOG/applescript.log" 2>&1
APP="$OUT/QLab Fallback Review.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun lipo -create "$OUT/QLabFallback-arm64" "$OUT/QLabFallback-x86_64" -output "$APP/Contents/MacOS/QLabFallback"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier fr.viking.qlabfallback.review' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName QLab Fallback Review' "$APP/Contents/Info.plist"
cp Resources/*.png Resources/*.icns "$APP/Contents/Resources/"
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources/"
codesign --force --sign - "$APP" > "$LOG/signing.log" 2>&1
codesign --verify --deep --strict "$APP" >> "$LOG/signing.log" 2>&1
printf '%s\n' 'PASS: both architectures, automated suites, Apple scripts/catalog and locally signed review app.'
