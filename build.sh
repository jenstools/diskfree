#!/bin/bash
#
# Builds DiskFree.app without Xcode (SwiftPM + a hand-assembled bundle + ad-hoc codesign).
#
#   ./build.sh              build .build/DiskFree.app
#   ./build.sh --install    also copy to /Applications and open it
#   ./build.sh --report     print what a scan finds, touch nothing
#   ./build.sh --release    universal app (Apple Silicon + Intel), zipped into dist/ for a GitHub release
#
# The icon is pre-rendered; regenerate it with: swift Resources/make-icon.swift
#
# Folder-access grants (Desktop, Documents, Downloads) are tied to the code signature,
# so an ad-hoc signed rebuild asks for them again.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DiskFree"
BUNDLE_ID="com.jenspolomski.diskfree"
APP="/Applications/${APP_NAME}.app"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }

if [ "${1:-}" = "--release" ]; then
    bold "Building universal binary (arm64 + x86_64)"
    swift build -c release --triple arm64-apple-macosx14.0
    swift build -c release --triple x86_64-apple-macosx14.0
    BINARY=".build/universal/${APP_NAME}"
    mkdir -p .build/universal
    lipo -create -output "$BINARY" \
        ".build/arm64-apple-macosx/release/${APP_NAME}" ".build/x86_64-apple-macosx/release/${APP_NAME}"
else
    bold "Building (release)"
    swift build -c release
    BINARY=".build/release/${APP_NAME}"
fi

if [ "${1:-}" = "--report" ]; then
    exec "$BINARY" --report
fi

STAGE=".build/${APP_NAME}.app"
rm -rf "$STAGE"
mkdir -p "${STAGE}/Contents/MacOS" "${STAGE}/Contents/Resources"
cp "$BINARY" "${STAGE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${STAGE}/Contents/Info.plist"
cp Resources/AppIcon.icns "${STAGE}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${STAGE}/Contents/PkgInfo"
codesign --force --sign - --identifier "$BUNDLE_ID" "$STAGE"
info "assembled and signed ${STAGE}"

if [ "${1:-}" = "--release" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
    ZIP="dist/${APP_NAME}-${VERSION}.zip"
    mkdir -p dist
    rm -f "$ZIP"
    ditto -c -k --keepParent "$STAGE" "$ZIP"
    bold "Done"
    info "$(lipo -archs "${STAGE}/Contents/MacOS/${APP_NAME}") app zipped to ${ZIP}"
    exit 0
fi

if [ "${1:-}" != "--install" ]; then
    bold "Done"
    info "run it:     open ${STAGE}"
    info "install it: ./build.sh --install"
    exit 0
fi

bold "Installing"
osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true
sleep 1
rm -rf "$APP"
cp -R "$STAGE" "$APP"
info "installed ${APP}"
open "$APP"
info "launched"
