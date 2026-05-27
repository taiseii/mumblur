#!/usr/bin/env bash
# Build Mumblur.app (Release), already ad-hoc-signed by Xcode, and optionally
# install to /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED="$ROOT/build"
xcodebuild \
    -project Mumblur.xcodeproj \
    -scheme Mumblur \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS' \
    build

APP="$DERIVED/Build/Products/Release/Mumblur.app"
if [[ ! -d "$APP" ]]; then
    echo "FAIL: build did not produce $APP" >&2
    exit 1
fi
echo "Built: $APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature' || true

if [[ "${1-}" == "--install" ]]; then
    rsync -a --delete "$APP" /Applications/
    echo "Installed to /Applications/Mumblur.app"
fi
