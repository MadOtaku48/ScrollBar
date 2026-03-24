#!/bin/bash
set -euo pipefail

APP_NAME="ScrollBar"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"

echo "==> Building release binary..."
swift build -c release

echo "==> Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${APP_BUNDLE}/Contents/Info.plist"

if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc code sign
codesign --force --sign - "${APP_BUNDLE}"

echo "==> Done: ${APP_BUNDLE}"

if [ "${1:-}" = "--install" ]; then
    echo "==> Installing to /Applications..."
    rm -rf "/Applications/${APP_BUNDLE}"
    cp -R "${APP_BUNDLE}" "/Applications/${APP_BUNDLE}"
    echo "==> Installed! Launch from Spotlight or /Applications."
else
    echo "    Run: open ${APP_BUNDLE}"
    echo "    Install: ./build-app.sh --install"
fi
