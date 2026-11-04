#!/bin/bash
set -euo pipefail
: "${RUNNER_TEMP:?}" "${APP_CERT_BASE64:?}" "${APP_CERT_PASSWORD:?}"
: "${INSTALLER_CERT_BASE64:?}" "${INSTALLER_CERT_PASSWORD:?}"
: "${APPLE_ID:?}" "${APPLE_APP_SPECIFIC_PASSWORD:?}" "${APPLE_TEAM_ID:?}"
cd "$(dirname "$0")/../.."
BUILD_DIRECTORY="$(cd "${1:?Informe a pasta da build}" && pwd)"
APP="$BUILD_DIRECTORY/Kontakt Add Libray.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]{2}$ ]] || { echo 'Versão inválida.'; exit 1; }
SIGNING_DIRECTORY="$(mktemp -d "$RUNNER_TEMP/kontakt-signing.XXXXXX")"
KEYCHAIN="$SIGNING_DIRECTORY/signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then echo "::add-mask::$KEYCHAIN_PASSWORD"; fi
EXISTING_KEYCHAINS=()
while IFS= read -r existing; do
    existing="${existing#*\"}"; existing="${existing%\"*}"
    [[ -z "$existing" ]] || EXISTING_KEYCHAINS+=("$existing")
done < <(security list-keychains -d user)
cleanup() {
    security list-keychains -d user -s "${EXISTING_KEYCHAINS[@]}" >/dev/null 2>&1 || true
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    rm -rf "$SIGNING_DIRECTORY"
}
trap cleanup EXIT
printf '%s' "$APP_CERT_BASE64" | base64 --decode > "$SIGNING_DIRECTORY/app.p12"
printf '%s' "$INSTALLER_CERT_BASE64" | base64 --decode > "$SIGNING_DIRECTORY/installer.p12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
import_identity() {
    if security import "$1" -k "$KEYCHAIN" -P "$2" -A -t cert -f pkcs12 > "$SIGNING_DIRECTORY/import.log" 2>&1; then
        return 0
    elif grep -Fq 'The specified item already exists in the keychain' "$SIGNING_DIRECTORY/import.log"; then
        return 0
    else
        cat "$SIGNING_DIRECTORY/import.log"; return 1
    fi
}
import_identity "$SIGNING_DIRECTORY/app.p12" "$APP_CERT_PASSWORD"
import_identity "$SIGNING_DIRECTORY/installer.p12" "$INSTALLER_CERT_PASSWORD"
rm -f "$SIGNING_DIRECTORY/app.p12" "$SIGNING_DIRECTORY/installer.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" "${EXISTING_KEYCHAINS[@]}"
APP_ID="$(security find-identity -v -p codesigning "$KEYCHAIN" | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
INSTALLER_ID="$(security find-identity -v "$KEYCHAIN" | sed -n 's/.*"\(Developer ID Installer:.*\)"/\1/p' | head -1)"
[[ -n "$APP_ID" && -n "$INSTALLER_ID" ]] || { echo 'Certificados Developer ID Application/Installer não encontrados.'; exit 1; }
[[ "$APP_ID" == *"($APPLE_TEAM_ID)" && "$INSTALLER_ID" == *"($APPLE_TEAM_ID)" ]] || { echo 'Os certificados não pertencem ao APPLE_TEAM_ID configurado.'; exit 1; }
for target in "$APP/Contents/MacOS/KontaktLibraryInstaller" "$APP"; do
    python3 scripts/codesign-with-retry.py --force --sign "$APP_ID" --keychain "$KEYCHAIN" --options runtime --timestamp "$target"
done
codesign --verify --deep --strict "$APP"
PACKAGE_STAGE="$(mktemp -d "$BUILD_DIRECTORY/package-stage.XXXXXX")"
mkdir -p "$PACKAGE_STAGE/Applications" "$BUILD_DIRECTORY/installer"
ditto "$APP" "$PACKAGE_STAGE/Applications/Kontakt Add Libray.app"
python3 - "$BUILD_DIRECTORY/component.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump([{'RootRelativeBundlePath': 'Applications/Kontakt Add Libray.app',
                   'BundleIsRelocatable': False, 'BundleOverwriteAction': 'upgrade'}], output)
PY
pkgbuild --root "$PACKAGE_STAGE" --component-plist "$BUILD_DIRECTORY/component.plist" \
    --identifier com.hookdeveloper.kontaktaddlibray.pkg --version "$VERSION" --install-location / "$BUILD_DIRECTORY/unsigned.pkg"
rm -rf "$PACKAGE_STAGE"
PKG="$BUILD_DIRECTORY/installer/Kontakt-Add-Libray-$VERSION-Mac.pkg"
python3 JarasLive/scripts/sign-catlive-pkg.py "$BUILD_DIRECTORY/unsigned.pkg" "$PKG" "$INSTALLER_ID" "$KEYCHAIN"
python3 JarasLive/scripts/notarize-catlive-pkg.py "$PKG" --result "$BUILD_DIRECTORY/notary-result.json"
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"
pkgutil --check-signature "$PKG"
(cd "$BUILD_DIRECTORY/installer" && shasum -a 256 "$(basename "$PKG")" > "$(basename "$PKG").sha256")
echo "Instalador assinado e notarizado: $PKG"
