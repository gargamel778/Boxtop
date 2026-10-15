#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Boxtop.app into ./build.
#   scripts/build-app.sh            release, universal
#   ARCHS="arm64" scripts/build-app.sh   single architecture
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=${ARCHS:-"arm64 x86_64"}
VERSION=${VERSION:-1.0.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}
ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done

echo "==> Compiling ($ARCHS)"
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR=$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)

APP=build/Boxtop.app
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Boxtop" "$APP/Contents/MacOS/Boxtop"
# The symbol table lists every source and object file by absolute path (the build machine's
# home folder). Keep the debug info in a dSYM next to the app for crash reports, then strip it.
rm -rf build/Boxtop.app.dSYM
dsymutil "$APP/Contents/MacOS/Boxtop" -o build/Boxtop.app.dSYM
strip -S -x "$APP/Contents/MacOS/Boxtop"
cp -R Resources/themes "$APP/Contents/Resources/themes"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE NOTICE "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Boxtop</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>dev.boxtop.Boxtop</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Boxtop</string>
    <key>CFBundleDisplayName</key><string>Boxtop</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>Derived from btop (Apache-2.0). See LICENSE and NOTICE.</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> Done"
lipo -info "$APP/Contents/MacOS/Boxtop"
echo "$APP"
