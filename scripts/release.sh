#!/bin/bash
set -euo pipefail

# Usage: ./scripts/release.sh 1.0.1
# One-time machine setup required:
#   - Developer ID Application cert in Keychain
#   - xcrun notarytool store-credentials "shoppinglist-notary" --apple-id YOUR_APPLE_ID --team-id T544U3WVL6 --password APP_SPECIFIC_PASSWORD
#   - Sparkle EdDSA private key in Keychain (already set up — shared with All Aboard)
#   - gh CLI authenticated

VERSION="${1:-}"
if [ -z "${VERSION}" ]; then
    echo "Usage: $0 <version>  e.g. $0 1.0.1"
    exit 1
fi

if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: version must be x.y.z"
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Error: working tree is dirty. Commit or stash changes first."
    exit 1
fi

PBXPROJ="Shopping List.xcodeproj/project.pbxproj"
BUILD_NUMBER=$(( $(git rev-list --count HEAD) + 1 ))

echo "==> Releasing v${VERSION} (build ${BUILD_NUMBER})"

sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = ${VERSION};/g" "${PBXPROJ}"
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = ${BUILD_NUMBER};/g" "${PBXPROJ}"

echo "==> Version bumped to ${VERSION} (${BUILD_NUMBER})"

./scripts/publish-update.sh

DMG="releases/stable/ShoppingList.dmg"

git add "${PBXPROJ}" appcast.xml
git commit -m "Release v${VERSION} (build ${BUILD_NUMBER})"
git tag "v${VERSION}"
git push origin main
git push origin "v${VERSION}"

echo "==> Creating GitHub release..."
gh release create "v${VERSION}" \
    "${DMG}#ShoppingList.dmg" \
    --title "v${VERSION}" \
    --notes "Shopping List v${VERSION}"

echo ""
echo "==> Done! v${VERSION} is live."
echo "    Sparkle will notify existing users automatically."
