#!/usr/bin/env bash
#
# Build Mumblur.app (Release, ad-hoc signed by Xcode), then zip it into
# `dist/Mumblur-<version>.zip` ready to attach to a GitHub Release.
#
# Usage:
#   scripts/package_release.sh                # uses MARKETING_VERSION from project.yml
#   scripts/package_release.sh v0.2.0         # forces a tag for the zip filename
#
# After tagging on git, upload with:
#   gh release create v0.2.0 dist/Mumblur-v0.2.0.zip --generate-notes
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED="$ROOT/build-release"
DIST="$ROOT/dist"
mkdir -p "$DIST"

# Resolve version: arg wins, else MARKETING_VERSION from project.yml, else "dev".
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    VERSION="$(grep -E '^\s*MARKETING_VERSION:' project.yml | head -1 | awk -F'"' '{print $2}')"
    VERSION="v${VERSION:-dev}"
fi

echo "==> Building Mumblur (Release) → $VERSION"
rm -rf "$DERIVED"
xcodebuild \
    -project Mumblur.xcodeproj \
    -scheme Mumblur \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS' \
    build | xcbeautify --quieter 2>/dev/null || true

APP="$DERIVED/Build/Products/Release/Mumblur.app"
if [[ ! -d "$APP" ]]; then
    echo "FAIL: build did not produce $APP" >&2
    exit 1
fi

echo "==> Verifying signature"
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature|Authority' || true

ZIP="$DIST/Mumblur-$VERSION.zip"
rm -f "$ZIP"
echo "==> Zipping → $ZIP"
# `ditto` preserves macOS bundle metadata (xattrs, symlinks) — `zip` corrupts .app bundles.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SIZE_HUMAN=$(du -h "$ZIP" | cut -f1)
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo
echo "==> Release artifact ready"
echo "    Path  : $ZIP"
echo "    Size  : $SIZE_HUMAN"
echo "    SHA256: $SHA"
echo
echo "To publish on GitHub:"
echo "    git tag -a $VERSION -m 'Release $VERSION' && git push origin $VERSION"
echo "    gh release create $VERSION $ZIP --generate-notes"
