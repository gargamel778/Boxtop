#!/bin/bash
# Tests, builds a universal Boxtop.app and packages it for a GitHub release.
#   VERSION=1.0.0 scripts/package-release.sh   ->   dist/Boxtop-1.0.0.zip and .sha256
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:?set VERSION, e.g. VERSION=1.0.0 scripts/package-release.sh}

echo "==> Testing"
swift test

VERSION="$VERSION" scripts/build-app.sh

echo "==> Packaging"
mkdir -p dist
ZIP="dist/Boxtop-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
# No extended attributes or __MACOSX entries in the archive.
xattr -cr build/Boxtop.app
codesign --force --deep --sign - build/Boxtop.app >/dev/null 2>&1
ditto -c -k --norsrc --keepParent build/Boxtop.app "$ZIP"
(cd dist && shasum -a 256 "Boxtop-$VERSION.zip" > "Boxtop-$VERSION.zip.sha256")
cat "$ZIP.sha256"
echo "$ZIP"
