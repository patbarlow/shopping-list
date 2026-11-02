#!/bin/bash
set -euo pipefail

APP_NAME="Trolley"
APP_BINARY="Trolley"
SCHEME="Shopping List macOS"
BUILD_DIR="${TMPDIR}shoppinglist-build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_BINARY}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
APP_PATH="${EXPORT_DIR}/${APP_BINARY}.app"
DMG_NAME="ShoppingList.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"

SIGN_IDENTITY="Developer ID Application: Pat Barlow (T544U3WVL6)"

echo "==> Cleaning build directory..."
rm -rf "${BUILD_DIR}"

echo "==> Archiving ${APP_NAME} (Release)..."
xcodebuild \
    -project "Shopping List.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    -archivePath "${ARCHIVE_PATH}" \
    -arch arm64 -arch x86_64 \
    ONLY_ACTIVE_ARCH=NO \
    clean archive

# Archive/export signs Sparkle's nested helpers correctly and preserves the
# app sandbox. Re-signing the whole app with --deep strips these entitlements.
cat > "${BUILD_DIR}/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
    <key>teamID</key><string>T544U3WVL6</string>
</dict></plist>
PLIST

echo "==> Exporting with: ${SIGN_IDENTITY}"
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist"

if [ ! -d "${APP_PATH}" ]; then
    echo "Error: Build failed — ${APP_PATH} not found"
    exit 1
fi

codesign --verify --deep --strict "${APP_PATH}"

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
