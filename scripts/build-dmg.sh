#!/bin/bash
set -euo pipefail

APP_NAME="Shopping List"
APP_BINARY="Shopping List macOS"
SCHEME="Shopping List macOS"
BUILD_DIR="${TMPDIR}shoppinglist-build"
APP_PATH="${BUILD_DIR}/Build/Products/Release/${APP_BINARY}.app"
DMG_NAME="ShoppingList.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"

SIGN_IDENTITY="Developer ID Application: Pat Barlow (T544U3WVL6)"

echo "==> Cleaning build directory..."
rm -rf "${BUILD_DIR}"

echo "==> Building ${APP_NAME} (Release)..."
xcodebuild \
    -project "Shopping List.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    -arch arm64 -arch x86_64 \
    ONLY_ACTIVE_ARCH=NO \
    clean build

if [ ! -d "${APP_PATH}" ]; then
    echo "Error: Build failed — ${APP_PATH} not found"
    exit 1
fi

echo "==> Signing with: ${SIGN_IDENTITY}"
codesign --force --deep --options runtime \
    --sign "${SIGN_IDENTITY}" \
    "${APP_PATH}"

echo "==> Creating DMG..."
STAGING_DIR="${BUILD_DIR}/dmg-staging"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"
rm -rf "${STAGING_DIR}"

echo "==> Signing DMG..."
codesign --force --sign "${SIGN_IDENTITY}" "${DMG_PATH}"

echo "==> Submitting for notarization..."
echo "    (Requires: xcrun notarytool store-credentials 'shoppinglist-notary' ...)"
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "shoppinglist-notary" \
    --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"

echo "==> Done! Output: ${DMG_PATH}"
