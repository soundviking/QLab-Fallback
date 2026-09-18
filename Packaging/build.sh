#!/bin/bash
set -euo pipefail
BUILD_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BUILD_ROOT"
mkdir -p Artifacts Resources
if [ -e Artifacts/QLab-Fallback-0.1.0-Build5.14-test-2Mac.pkg ]; then
  echo "Package existant : refus d’écraser. Choisir une nouvelle livraison." >&2
  exit 1
fi
CACHE_DIR="${TMPDIR:-/tmp}/qlab-build514test-module-cache"
for ARCH in arm64 x86_64; do
  xcrun swiftc -module-cache-path "$CACHE_DIR-$ARCH" -target "$ARCH-apple-macosx14.0" -parse-as-library Sources/*.swift -framework Security -o "Artifacts/QLabFallback-$ARCH" > "compile-$ARCH.log" 2>&1
done
xcrun swiftc -module-cache-path "$CACHE_DIR-tests" -parse-as-library Sources/LiveMirror*.swift Tests/LiveMirrorTests.swift -o Artifacts/run-tests > tests-compile.log 2>&1
Artifacts/run-tests > tests.log 2>&1
xcrun swiftc -module-cache-path "$CACHE_DIR-tests" -parse-as-library Sources/LiveMirror*.swift Sources/QLabOSCClient.swift Sources/WorkspaceTransferSupport.swift Sources/RecoverySupport.swift Tests/RegressionTests.swift -o Artifacts/run-regression-tests > regression-compile.log 2>&1
Artifacts/run-regression-tests > regression-tests.log 2>&1
xcrun swiftc -module-cache-path "$CACHE_DIR-tests" -parse-as-library Sources/LiveMirror*.swift Tests/WorkspaceSignatureTests.swift -o Artifacts/run-signature-tests > signature-compile.log 2>&1
python3 Tests/workspace-signature-tests.py Artifacts/run-signature-tests > Validation/signature.log
python3 Packaging/check-scripts.py > applescript-compile.log
xcrun swiftc -module-cache-path "$CACHE_DIR-tests" -parse-as-library Sources/LiveMirror*.swift Sources/ResponsivenessPolicy.swift Sources/WorkspaceBinaryTransfer.swift Tests/BinaryTransferTests.swift -o Artifacts/run-binary-tests > binary-compile.log 2>&1
Artifacts/run-binary-tests > Validation/binary-transfer.log 2>&1
bash Tests/run-osc-tests.sh > Validation/osc-recovery.log 2>&1
APP_ROOT="$BUILD_ROOT/Artifacts/payload"
APP="$APP_ROOT/QLab Fallback Build5.14-test.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun lipo -create Artifacts/QLabFallback-arm64 Artifacts/QLabFallback-x86_64 -output "$APP/Contents/MacOS/QLabFallback"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp Resources/* "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" > codesign-verify.log 2>&1
pkgbuild --analyze --root "$APP_ROOT" Artifacts/components.plist
python3 - <<'PY'
import plistlib
from pathlib import Path
p = Path('Artifacts/components.plist')
items = plistlib.loads(p.read_bytes())
for item in items:
    item['BundleIsRelocatable'] = False
    item['BundleHasStrictIdentifier'] = True
    item['BundleOverwriteAction'] = 'upgrade'
p.write_bytes(plistlib.dumps(items))
PY
pkgbuild --root "$APP_ROOT" --component-plist Artifacts/components.plist --install-location /Applications --identifier fr.viking.qlabfallback.build514test --version 0.1.0.514 Artifacts/QLab-Fallback-0.1.0-Build5.14-test-2Mac.pkg > package-build.log 2>&1
pkgutil --payload-files Artifacts/QLab-Fallback-0.1.0-Build5.14-test-2Mac.pkg > package-payload.log
printf '%s\n' 'Build5.14-test: compilation, tests, signature locale et PKG terminés.'
