#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TouchMacer"
APP_DIR="${APP_DIR:-$ROOT_DIR/.build/app/$APP_NAME.app}"
UPDATES_DIR="${UPDATES_DIR:-$ROOT_DIR/.build/updates}"
SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$ROOT_DIR/.build/artifacts/touch-macer/Sparkle/bin}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-com.touchmacer.clock.sparkle}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-2L5YC85FQ7}"
EXPECTED_CODESIGN_AUTHORITY="${EXPECTED_CODESIGN_AUTHORITY:-Apple Development: talexdreamsoul@gmail.com (GCTF54QXD3)}"
EXPECTED_VERSION="${EXPECTED_VERSION:-}"
EXPECTED_BUILD="${EXPECTED_BUILD:-}"
RELEASE_BASE_URL="https://github.com/TalexDreamSoul/touch-macer/releases/download"

GENERATE_APPCAST="$SPARKLE_TOOLS_DIR/generate_appcast"
GENERATE_KEYS="$SPARKLE_TOOLS_DIR/generate_keys"
SIGN_UPDATE="$SPARKLE_TOOLS_DIR/sign_update"
INFO_PLIST="$APP_DIR/Contents/Info.plist"

for executable in "$GENERATE_APPCAST" "$GENERATE_KEYS" "$SIGN_UPDATE"; do
    if [[ ! -x "$executable" ]]; then
        echo "Missing Sparkle tool: $executable" >&2
        exit 1
    fi
done
if [[ ! -f "$INFO_PLIST" ]]; then
    echo "Missing packaged TouchMacer app: $APP_DIR" >&2
    exit 1
fi
if [[ -z "$EXPECTED_VERSION" || -z "$EXPECTED_BUILD" ]]; then
    echo "EXPECTED_VERSION and EXPECTED_BUILD are required for release packaging." >&2
    exit 1
fi

verify_stable_signature() {
    local component="$1"
    local details
    local requirement
    codesign --verify --strict "$component"
    details="$(codesign -d --verbose=4 "$component" 2>&1)"
    requirement="$(codesign -d -r- "$component" 2>&1 | tail -1)"
    if ! grep -q "TeamIdentifier=$EXPECTED_TEAM_ID" <<<"$details"; then
        echo "Unexpected or missing TeamIdentifier for $component." >&2
        exit 1
    fi
    if ! grep -Fq "Authority=$EXPECTED_CODESIGN_AUTHORITY" <<<"$details"; then
        echo "Unexpected signing certificate for $component." >&2
        exit 1
    fi
    if grep -q 'designated => cdhash' <<<"$requirement"; then
        echo "Ad-hoc designated requirement is forbidden for OTA: $component" >&2
        exit 1
    fi
}

SPARKLE_VERSION_DIR="$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B"
verify_stable_signature "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
verify_stable_signature "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
verify_stable_signature "$SPARKLE_VERSION_DIR/Autoupdate"
verify_stable_signature "$SPARKLE_VERSION_DIR/Updater.app"
verify_stable_signature "$APP_DIR/Contents/Frameworks/Sparkle.framework"
HELPER_PATH="$APP_DIR/Contents/Library/HelperTools/TouchMacerHelper"
verify_stable_signature "$HELPER_PATH"
verify_stable_signature "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

CERTIFICATE_REQUIREMENT="anchor apple generic and certificate leaf[subject.CN] = \"$EXPECTED_CODESIGN_AUTHORITY\" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"
EXPECTED_APP_REQUIREMENT="designated => identifier \"com.touchmacer.clock\" and $CERTIFICATE_REQUIREMENT"
EXPECTED_HELPER_REQUIREMENT="designated => identifier TouchMacerHelper and $CERTIFICATE_REQUIREMENT"
APP_REQUIREMENT="$(codesign -d -r- "$APP_DIR" 2>&1 | tail -1)"
HELPER_REQUIREMENT="$(codesign -d -r- "$HELPER_PATH" 2>&1 | tail -1)"
[[ "$APP_REQUIREMENT" == "$EXPECTED_APP_REQUIREMENT" ]] || {
    echo "TouchMacer designated requirement changed unexpectedly." >&2
    exit 1
}
[[ "$HELPER_REQUIREMENT" == "$EXPECTED_HELPER_REQUIREMENT" ]] || {
    echo "TouchMacerHelper designated requirement changed unexpectedly." >&2
    exit 1
}

EXPECTED_FEED_URL="https://github.com/TalexDreamSoul/touch-macer/releases/download/appcast-feed/appcast.xml"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$INFO_PLIST")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUAutomaticallyUpdate' "$INFO_PLIST")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUScheduledCheckInterval' "$INFO_PLIST")" == "43200" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST")" == "$EXPECTED_FEED_URL" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$INFO_PLIST")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$INFO_PLIST")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDevelopmentRegion' "$INFO_PLIST")" == "en" ]]
for localization in en zh-Hans; do
    [[ -f "$APP_DIR/Contents/Resources/$localization.lproj/Localizable.strings" ]]
    [[ -f "$APP_DIR/Contents/Resources/$localization.lproj/InfoPlist.strings" ]]
    plutil -lint "$APP_DIR/Contents/Resources/$localization.lproj/Localizable.strings" >/dev/null
    plutil -lint "$APP_DIR/Contents/Resources/$localization.lproj/InfoPlist.strings" >/dev/null
done
"$ROOT_DIR/scripts/verify-localizations.swift" \
    "$APP_DIR/Contents/Resources/en.lproj/Localizable.strings" \
    "$APP_DIR/Contents/Resources/zh-Hans.lproj/Localizable.strings" >/dev/null

PACKAGED_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")"
KEYCHAIN_PUBLIC_KEY="$("$GENERATE_KEYS" --account "$SPARKLE_KEY_ACCOUNT" -p)"
if [[ "$PACKAGED_PUBLIC_KEY" != "$KEYCHAIN_PUBLIC_KEY" ]]; then
    echo "Packaged Sparkle public key does not match the selected Keychain account." >&2
    exit 1
fi

BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
[[ "$BUNDLE_IDENTIFIER" == "com.touchmacer.clock" ]] || {
    echo "Unexpected bundle identifier: $BUNDLE_IDENTIFIER" >&2
    exit 1
}
[[ "$VERSION" == "$EXPECTED_VERSION" && "$BUILD_NUMBER" == "$EXPECTED_BUILD" ]] || {
    echo "Expected TouchMacer $EXPECTED_VERSION ($EXPECTED_BUILD), got $VERSION ($BUILD_NUMBER)." >&2
    exit 1
}
ARCHIVE_NAME="$APP_NAME-v$VERSION-macos.zip"
ARCHIVE_PATH="$UPDATES_DIR/$ARCHIVE_NAME"
APPCAST_PATH="$UPDATES_DIR/appcast.xml"
DOWNLOAD_URL_PREFIX="$RELEASE_BASE_URL/v$VERSION/"

mkdir -p "$UPDATES_DIR"
rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_PATH"

GENERATION_DIR="$(mktemp -d -t touchmacer-appcast)"
trap 'rm -rf "$GENERATION_DIR"' EXIT
cp "$ARCHIVE_PATH" "$GENERATION_DIR/$ARCHIVE_NAME"
if [[ -f "$APPCAST_PATH" ]]; then
    cp "$APPCAST_PATH" "$GENERATION_DIR/appcast.xml"
fi
GENERATION_APPCAST_PATH="$GENERATION_DIR/appcast.xml"

"$GENERATE_APPCAST" \
    --account "$SPARKLE_KEY_ACCOUNT" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --maximum-deltas 0 \
    --maximum-versions 10 \
    -o "$GENERATION_APPCAST_PATH" \
    "$GENERATION_DIR"

"$SIGN_UPDATE" --account "$SPARKLE_KEY_ACCOUNT" "$GENERATION_APPCAST_PATH" >/dev/null
"$SIGN_UPDATE" --account "$SPARKLE_KEY_ACCOUNT" --verify "$GENERATION_APPCAST_PATH"
mv "$GENERATION_APPCAST_PATH" "$APPCAST_PATH"

ARCHIVE_SIGNATURE="$(xmllint --xpath \
    "string(//*[local-name()='enclosure'][contains(@url, '$ARCHIVE_NAME')]/@*[local-name()='edSignature'])" \
    "$APPCAST_PATH")"
if [[ -z "$ARCHIVE_SIGNATURE" ]]; then
    echo "Missing EdDSA enclosure signature for $ARCHIVE_NAME." >&2
    exit 1
fi
"$SIGN_UPDATE" \
    --account "$SPARKLE_KEY_ACCOUNT" \
    --verify "$ARCHIVE_PATH" \
    "$ARCHIVE_SIGNATURE"

ARCHIVE_SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
ARCHIVE_SIZE="$(stat -f '%z' "$ARCHIVE_PATH")"
printf 'version=%s\nbuild=%s\narchive=%s\nsize=%s\nsha256=%s\nappcast=%s\n' \
    "$VERSION" \
    "$BUILD_NUMBER" \
    "$ARCHIVE_PATH" \
    "$ARCHIVE_SIZE" \
    "$ARCHIVE_SHA256" \
    "$APPCAST_PATH"
