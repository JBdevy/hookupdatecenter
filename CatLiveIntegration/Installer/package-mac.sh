#!/bin/bash
set -euo pipefail
: "${RUNNER_TEMP:?}" "${APP_CERT_BASE64:?}" "${APP_CERT_PASSWORD:?}" "${INSTALLER_CERT_BASE64:?}" "${INSTALLER_CERT_PASSWORD:?}" "${APPLE_ID:?}" "${APPLE_APP_SPECIFIC_PASSWORD:?}" "${APPLE_TEAM_ID:?}"
BUILD_DIRECTORY="$1"
set -euo pipefail
KEYCHAIN="$RUNNER_TEMP/catlive-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
echo "::add-mask::$KEYCHAIN_PASSWORD"
printf '%s' "$APP_CERT_BASE64" | base64 --decode > "$RUNNER_TEMP/catlive-app.p12"
printf '%s' "$INSTALLER_CERT_BASE64" | base64 --decode > "$RUNNER_TEMP/catlive-installer.p12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# This keychain exists only for this job. Avoid an invisible GUI access
# prompt when productsign requests the Installer private key.
import_identity() {
  local certificate="$1" password="$2"
  local output="$RUNNER_TEMP/catlive-identity-import.log"
  if security import "$certificate" -k "$KEYCHAIN" -P "$password" -A -t cert -f pkcs12 > "$output" 2>&1; then
    cat "$output"
  elif grep -Fq 'The specified item already exists in the keychain' "$output"; then
    echo 'Shared certificate already imported; checking identities below.'
  else
    cat "$output"
    return 1
  fi
}
import_identity "$RUNNER_TEMP/catlive-app.p12" "$APP_CERT_PASSWORD"
import_identity "$RUNNER_TEMP/catlive-installer.p12" "$INSTALLER_CERT_PASSWORD"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
EXISTING_KEYCHAINS=()
while IFS= read -r existing; do
  existing="${existing//\"/}"
  [[ -z "$existing" || "$existing" == "$KEYCHAIN" ]] || EXISTING_KEYCHAINS+=("$existing")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KEYCHAIN" "${EXISTING_KEYCHAINS[@]}"
rm -f "$RUNNER_TEMP/catlive-app.p12" "$RUNNER_TEMP/catlive-installer.p12"
security find-identity -v -p codesigning "$KEYCHAIN" | grep -q 'Developer ID Application:'
security find-identity -v "$KEYCHAIN" | grep -q 'Developer ID Installer:'
echo "CATLIVE_KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"
echo "CATLIVE_KEYCHAIN_PASSWORD=$KEYCHAIN_PASSWORD" >> "$GITHUB_ENV"
APP="$BUILD_DIRECTORY/CatLive Integration.app"
APP_ID="$(security find-identity -v -p codesigning "$KEYCHAIN" | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
INSTALLER_ID="$(security find-identity -v "$KEYCHAIN" | sed -n 's/.*"\(Developer ID Installer:.*\)"/\1/p' | head -1)"
python3 scripts/codesign-with-retry.py --force --sign "$APP_ID" --options runtime --timestamp "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$BUILD_DIRECTORY/installer"
python3 - "$BUILD_DIRECTORY/component.plist" <<'PYCOMPONENT'
import plistlib,sys
with open(sys.argv[1],'wb') as out:
    plistlib.dump([{'RootRelativeBundlePath':'Applications/CatLive Integration.app','BundleIsRelocatable':False,'BundleOverwriteAction':'upgrade'}],out)
PYCOMPONENT
mkdir -p "$BUILD_DIRECTORY/pkg-root/Applications"
ditto "$APP" "$BUILD_DIRECTORY/pkg-root/Applications/CatLive Integration.app"
pkgbuild --root "$BUILD_DIRECTORY/pkg-root" --component-plist "$BUILD_DIRECTORY/component.plist" --identifier com.hookdeveloper.catlive.integration.pkg --version 1.26 --install-location / "$BUILD_DIRECTORY/unsigned.pkg"
PKG="$BUILD_DIRECTORY/installer/CatLive-Integration-1.26-Mac.pkg"
python3 JarasLive/scripts/sign-catlive-pkg.py "$BUILD_DIRECTORY/unsigned.pkg" "$PKG" "$INSTALLER_ID" "$KEYCHAIN"
python3 JarasLive/scripts/notarize-catlive-pkg.py "$PKG" --result "$BUILD_DIRECTORY/notary-result.json"
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"
pkgutil --check-signature "$PKG"
shasum -a 256 "$PKG" > "$PKG.sha256"
