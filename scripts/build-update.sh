#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MenuCue"
HELPER_NAME="MenuCueHelper"
BUNDLE_IDENTIFIER="com.tagzxia.app.menucue"
HELPER_BUNDLE_IDENTIFIER="com.tagzxia.app.menucue.helper"
APP_DIR="${APP_DIR:-$ROOT_DIR/.build/app/$APP_NAME.app}"
UPDATES_DIR="${UPDATES_DIR:-$ROOT_DIR/.build/updates}"
SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$ROOT_DIR/.build/artifacts/menucue/Sparkle/bin}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-com.tagzxia.app.menucue.sparkle}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-2L5YC85FQ7}"
EXPECTED_CODESIGN_AUTHORITY="${EXPECTED_CODESIGN_AUTHORITY:-Developer ID Application: ZiXian Tang (2L5YC85FQ7)}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
NOTARIZATION_MAX_ATTEMPTS="${NOTARIZATION_MAX_ATTEMPTS:-3}"
NOTARIZATION_RETRY_DELAY="${NOTARIZATION_RETRY_DELAY:-30}"
EXPECTED_VERSION="${EXPECTED_VERSION:-}"
EXPECTED_BUILD="${EXPECTED_BUILD:-}"
RELEASE_BASE_URL="https://github.com/TalexDreamSoul/menucue/releases/download"

GENERATE_APPCAST="$SPARKLE_TOOLS_DIR/generate_appcast"
GENERATE_KEYS="$SPARKLE_TOOLS_DIR/generate_keys"
SIGN_UPDATE="$SPARKLE_TOOLS_DIR/sign_update"
INFO_PLIST="$APP_DIR/Contents/Info.plist"
EMBEDDED_PROFILE="$APP_DIR/Contents/embedded.provisionprofile"
APP_ENTITLEMENTS_PLIST="$ROOT_DIR/.build/MenuCue.release.entitlements.plist"
PROFILE_PLIST="$ROOT_DIR/.build/MenuCue.release.profile.plist"

for executable in "$GENERATE_APPCAST" "$GENERATE_KEYS" "$SIGN_UPDATE"; do
    if [[ ! -x "$executable" ]]; then
        echo "Missing Sparkle tool: $executable" >&2
        exit 1
    fi
done
if [[ ! -f "$INFO_PLIST" ]]; then
    echo "Missing packaged MenuCue app: $APP_DIR" >&2
    exit 1
fi
if [[ -z "$EXPECTED_VERSION" || -z "$EXPECTED_BUILD" ]]; then
    echo "EXPECTED_VERSION and EXPECTED_BUILD are required for release packaging." >&2
    exit 1
fi
if [[ -z "$NOTARYTOOL_PROFILE" ]]; then
    echo "NOTARYTOOL_PROFILE is required for notarized release packaging." >&2
    exit 1
fi
if [[ ! "$NOTARIZATION_MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ \
    || ! "$NOTARIZATION_RETRY_DELAY" =~ ^[1-9][0-9]*$ ]]; then
    echo "Notarization retry settings must be positive integers." >&2
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
    if ! grep -q 'flags=.*runtime' <<<"$details"; then
        echo "Hardened runtime is required for $component." >&2
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
HELPER_PATH="$APP_DIR/Contents/Library/HelperTools/$HELPER_NAME"
verify_stable_signature "$HELPER_PATH"
verify_stable_signature "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

if [[ ! -f "$EMBEDDED_PROFILE" ]]; then
    echo "Release app is missing its embedded iCloud provisioning profile." >&2
    exit 1
fi
if ! codesign -d --entitlements :- "$APP_DIR" > "$APP_ENTITLEMENTS_PLIST" 2>/dev/null; then
    echo "Could not read release app entitlements." >&2
    exit 1
fi
security cms -D -i "$EMBEDDED_PROFILE" > "$PROFILE_PLIST"
PROFILE_ALL_DEVICES="$(/usr/libexec/PlistBuddy \
    -c 'Print :ProvisionsAllDevices' "$PROFILE_PLIST" 2>/dev/null || echo false)"
PROFILE_GET_TASK_ALLOW="$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.security.get-task-allow' \
    "$PROFILE_PLIST" 2>/dev/null || echo false)"
[[ "$PROFILE_ALL_DEVICES" == "true" ]] || {
    echo "Embedded release profile does not authorize all devices." >&2
    exit 1
}
if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' \
    "$PROFILE_PLIST" >/dev/null 2>&1; then
    echo "Embedded release profile is device-bound." >&2
    exit 1
fi
[[ "$PROFILE_GET_TASK_ALLOW" != "true" ]] || {
    echo "Embedded release profile enables debugging." >&2
    exit 1
}
EXPECTED_APPLICATION_IDENTIFIER="$EXPECTED_TEAM_ID.$BUNDLE_IDENTIFIER"
APP_APPLICATION_IDENTIFIER="$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.application-identifier' "$APP_ENTITLEMENTS_PLIST")"
APP_KVSTORE_IDENTIFIER="$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.ubiquity-kvstore-identifier' "$APP_ENTITLEMENTS_PLIST")"
PROFILE_APPLICATION_IDENTIFIER="$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")"
PROFILE_KVSTORE_IDENTIFIER="$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.developer.ubiquity-kvstore-identifier' "$PROFILE_PLIST")"
[[ "$APP_APPLICATION_IDENTIFIER" == "$EXPECTED_APPLICATION_IDENTIFIER" ]] || {
    echo "Release app identifier entitlement does not match $BUNDLE_IDENTIFIER." >&2
    exit 1
}
[[ "$APP_KVSTORE_IDENTIFIER" == "$EXPECTED_APPLICATION_IDENTIFIER" ]] || {
    echo "Release app is missing the required iCloud key-value entitlement." >&2
    exit 1
}
[[ "$PROFILE_APPLICATION_IDENTIFIER" == "$EXPECTED_APPLICATION_IDENTIFIER" ]] || {
    echo "Embedded profile does not authorize $BUNDLE_IDENTIFIER." >&2
    exit 1
}
[[ "$PROFILE_KVSTORE_IDENTIFIER" == "$EXPECTED_APPLICATION_IDENTIFIER" \
    || "$PROFILE_KVSTORE_IDENTIFIER" == "$EXPECTED_TEAM_ID.*" ]] || {
    echo "Embedded profile does not authorize MenuCue iCloud key-value storage." >&2
    exit 1
}

APP_REQUIREMENT="$(codesign -d -r- "$APP_DIR" 2>&1 | tail -1)"
HELPER_REQUIREMENT="$(codesign -d -r- "$HELPER_PATH" 2>&1 | tail -1)"
for requirement in "$APP_REQUIREMENT" "$HELPER_REQUIREMENT"; do
    if [[ "$requirement" != *"anchor apple generic"* \
        || "$requirement" != *"certificate 1[field.1.2.840.113635.100.6.2.6]"* \
        || "$requirement" != *"certificate leaf[field.1.2.840.113635.100.6.1.13]"* \
        || "$requirement" != *"certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""* ]]; then
        echo "Developer ID designated requirement changed unexpectedly." >&2
        exit 1
    fi
done

EXPECTED_FEED_URL="$RELEASE_BASE_URL/appcast-feed/appcast.xml"
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

PACKAGED_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
[[ "$PACKAGED_BUNDLE_IDENTIFIER" == "$BUNDLE_IDENTIFIER" ]] || {
    echo "Unexpected bundle identifier: $PACKAGED_BUNDLE_IDENTIFIER" >&2
    exit 1
}
[[ "$VERSION" == "$EXPECTED_VERSION" && "$BUILD_NUMBER" == "$EXPECTED_BUILD" ]] || {
    echo "Expected $APP_NAME $EXPECTED_VERSION ($EXPECTED_BUILD), got $VERSION ($BUILD_NUMBER)." >&2
    exit 1
}
ARCHIVE_NAME="$APP_NAME-v$VERSION-macos.zip"
ARCHIVE_PATH="$UPDATES_DIR/$ARCHIVE_NAME"
APPCAST_PATH="$UPDATES_DIR/appcast.xml"
DOWNLOAD_URL_PREFIX="$RELEASE_BASE_URL/v$VERSION/"

NOTARIZATION_DIR="$(mktemp -d -t menucue-notarization)"
GENERATION_DIR=""
cleanup() {
    rm -rf "$NOTARIZATION_DIR"
    if [[ -n "$GENERATION_DIR" ]]; then
        rm -rf "$GENERATION_DIR"
    fi
}
trap cleanup EXIT
NOTARIZATION_ARCHIVE="$NOTARIZATION_DIR/$APP_NAME-notarization.zip"
NOTARIZATION_RESULT="$NOTARIZATION_DIR/notarization.json"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$NOTARIZATION_ARCHIVE"
NOTARIZATION_ATTEMPT=1
while true; do
    rm -f "$NOTARIZATION_RESULT"
    if xcrun notarytool submit "$NOTARIZATION_ARCHIVE" \
        --keychain-profile "$NOTARYTOOL_PROFILE" \
        --wait \
        --output-format json > "$NOTARIZATION_RESULT"; then
        break
    fi
    if (( NOTARIZATION_ATTEMPT >= NOTARIZATION_MAX_ATTEMPTS )); then
        echo "Apple notarization submission failed after $NOTARIZATION_ATTEMPT attempts." >&2
        exit 1
    fi
    RETRY_WAIT_SECONDS=$((NOTARIZATION_RETRY_DELAY * NOTARIZATION_ATTEMPT))
    echo "Apple notarization is temporarily unavailable; retrying in ${RETRY_WAIT_SECONDS}s." >&2
    sleep "$RETRY_WAIT_SECONDS"
    ((NOTARIZATION_ATTEMPT += 1))
done
NOTARIZATION_STATUS="$(jq -r '.status // empty' "$NOTARIZATION_RESULT")"
NOTARIZATION_ID="$(jq -r '.id // empty' "$NOTARIZATION_RESULT")"
if [[ "$NOTARIZATION_STATUS" != "Accepted" || -z "$NOTARIZATION_ID" ]]; then
    echo "Apple notarization was not accepted (status: ${NOTARIZATION_STATUS:-unknown})." >&2
    exit 1
fi
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
spctl --assess --type execute --verbose=4 "$APP_DIR"

mkdir -p "$UPDATES_DIR"
rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_PATH"

GENERATION_DIR="$(mktemp -d -t menucue-appcast)"
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
printf 'version=%s\nbuild=%s\nnotarization_id=%s\narchive=%s\nsize=%s\nsha256=%s\nappcast=%s\n' \
    "$VERSION" \
    "$BUILD_NUMBER" \
    "$NOTARIZATION_ID" \
    "$ARCHIVE_PATH" \
    "$ARCHIVE_SIZE" \
    "$ARCHIVE_SHA256" \
    "$APPCAST_PATH"
