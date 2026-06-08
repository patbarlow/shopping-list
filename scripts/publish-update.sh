#!/bin/bash
set -euo pipefail

SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData/Shopping_List-*/SourcePackages/artifacts/sparkle/Sparkle/bin -name generate_appcast -print -quit 2>/dev/null)"

if [ -z "${SPARKLE_BIN}" ]; then
    echo "Error: Sparkle generate_appcast not found. Build the project in Xcode first."
    exit 1
fi

SPARKLE_DIR="$(dirname "${SPARKLE_BIN}")"

echo "==> Building DMG..."
./scripts/build-dmg.sh

RELEASES_DIR="$(pwd)/releases/stable"
mkdir -p "${RELEASES_DIR}"

cp "${TMPDIR}shoppinglist-build/ShoppingList.dmg" "${RELEASES_DIR}/ShoppingList.dmg"

echo "==> Generating appcast..."
"${SPARKLE_DIR}/generate_appcast" "${RELEASES_DIR}" \
    --download-url-prefix "https://github.com/patbarlow/shopping-list/releases/latest/download/"

cp "${RELEASES_DIR}/appcast.xml" "$(pwd)/appcast.xml"

# Ensure the enclosure has an EdDSA signature
DMG_FILE="${RELEASES_DIR}/ShoppingList.dmg"
if ! grep -q 'sparkle:edSignature' "$(pwd)/appcast.xml"; then
    echo "==> generate_appcast did not sign — running sign_update directly..."
    SIGNATURE=$("${SPARKLE_DIR}/sign_update" "${DMG_FILE}" 2>/dev/null | grep -o 'sparkle:edSignature="[^"]*"')
    DMG_SIZE=$(stat -f "%z" "${DMG_FILE}")
    if [ -n "${SIGNATURE}" ]; then
        sed -i '' \
            "s|<enclosure url=\"\([^\"]*\)\" length=\"[0-9]*\"|<enclosure url=\"\1\" ${SIGNATURE} length=\"${DMG_SIZE}\"|g" \
            "$(pwd)/appcast.xml"
        echo "==> Signature injected."
    else
        echo "Warning: sign_update also failed. Update will not install until signed."
    fi
fi

echo "==> Done! appcast.xml updated."
