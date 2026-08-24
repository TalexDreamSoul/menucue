#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MenuCue"
DISPLAY_NAME="MenuCue"
HELPER_NAME="MenuCueHelper"
BUNDLE_IDENTIFIER="com.tagzxia.app.menucue"
HELPER_BUNDLE_IDENTIFIER="com.tagzxia.app.menucue.helper"
HELPER_PLIST_NAME="$HELPER_BUNDLE_IDENTIFIER.plist"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
APP_VERSION="0.7.1"
BUILD_NUMBER="32"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
REQUIRE_STABLE_SIGNING="${REQUIRE_STABLE_SIGNING:-false}"
SPARKLE_PUBLIC_ED_KEY="3UilJjqjrxBl53x71Fe2Kidf1uIooNLoOFL/6c13qyg="
SPARKLE_FEED_URL="https://github.com/TalexDreamSoul/menucue/releases/download/appcast-feed/appcast.xml"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-}"
RESOLVED_APP_ENTITLEMENTS="$ROOT_DIR/.build/MenuCue.resolved.entitlements"
PROFILE_PLIST="$ROOT_DIR/.build/MenuCue.profile.plist"
ICON_SOURCE="$ROOT_DIR/assets/AppIcon.png"
APP_DIR="$ROOT_DIR/.build/app/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
LAUNCH_DAEMONS_DIR="$CONTENTS_DIR/Library/LaunchDaemons"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
ICNS_PATH="$ROOT_DIR/.build/AppIcon.icns"
SPARKLE_FRAMEWORK_SOURCE="$ROOT_DIR/.build/$BUILD_CONFIG/Sparkle.framework"
SPARKLE_FRAMEWORK_DESTINATION="$FRAMEWORKS_DIR/Sparkle.framework"
LOCALIZATION_BUNDLE_SOURCE="$ROOT_DIR/.build/$BUILD_CONFIG/MenuCue_MenuCue.bundle"

cd "$ROOT_DIR"
if [[ "$REQUIRE_STABLE_SIGNING" == "true" ]]; then
    if [[ "$CODESIGN_IDENTITY" != "Developer ID Application:"* ]]; then
        echo "Stable release builds require a Developer ID Application identity." >&2
        exit 1
    fi
    if ! security find-identity -v -p codesigning \
        | grep -Fq "\"$CODESIGN_IDENTITY\""; then
        echo "Developer ID signing identity is unavailable: $CODESIGN_IDENTITY" >&2
        exit 1
    fi
    if [[ -z "$APPLE_TEAM_ID" ]]; then
        echo "APPLE_TEAM_ID is required for stable release builds." >&2
        exit 1
    fi
fi
CODESIGN_ARGS=(--force --sign "$CODESIGN_IDENTITY")
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    CODESIGN_ARGS+=(--options runtime)
fi
if [[ "$CODESIGN_IDENTITY" == "Developer ID Application:"* ]]; then
    CODESIGN_ARGS+=(--timestamp)
fi
swift build -c "$BUILD_CONFIG"

if [[ ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
    echo "Missing Sparkle framework: $SPARKLE_FRAMEWORK_SOURCE" >&2
    exit 1
fi
if [[ ! -d "$LOCALIZATION_BUNDLE_SOURCE" ]]; then
    echo "Missing MenuCue localization bundle: $LOCALIZATION_BUNDLE_SOURCE" >&2
    exit 1
fi

rm -rf "$APP_DIR" "$ICONSET_DIR" "$ICNS_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR" "$LAUNCH_DAEMONS_DIR" "$ICONSET_DIR"
cp "$ROOT_DIR/.build/$BUILD_CONFIG/$APP_NAME" "$MACOS_DIR/$APP_NAME"
ditto "$SPARKLE_FRAMEWORK_SOURCE" "$SPARKLE_FRAMEWORK_DESTINATION"
ditto "$LOCALIZATION_BUNDLE_SOURCE/en.lproj" "$RESOURCES_DIR/en.lproj"
ZH_HANS_SOURCE="$(find "$LOCALIZATION_BUNDLE_SOURCE" -maxdepth 1 -type d -iname 'zh-hans.lproj' -print -quit)"
if [[ -z "$ZH_HANS_SOURCE" ]]; then
    echo "Missing zh-Hans localization in $LOCALIZATION_BUNDLE_SOURCE" >&2
    exit 1
fi
ditto "$ZH_HANS_SOURCE" "$RESOURCES_DIR/zh-Hans.lproj"
for resource in \
    solar-terms-1901-2100.json \
    solar-terms-1901-2100.metadata.json; do
    if [[ ! -f "$LOCALIZATION_BUNDLE_SOURCE/$resource" ]]; then
        echo "Missing bundled calendar resource: $resource" >&2
        exit 1
    fi
    cp "$LOCALIZATION_BUNDLE_SOURCE/$resource" "$RESOURCES_DIR/$resource"
done
cp "$ROOT_DIR/.build/$BUILD_CONFIG/$HELPER_NAME" "$MACOS_DIR/$HELPER_NAME"
cp "$ROOT_DIR/Resources/$HELPER_PLIST_NAME" "$LAUNCH_DAEMONS_DIR/$HELPER_PLIST_NAME"
chmod +x "$MACOS_DIR/$APP_NAME" "$MACOS_DIR/$HELPER_NAME"

if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "Missing icon source: $ICON_SOURCE" >&2
    exit 1
fi

make_icon() {
    local size="$1"
    local filename="$2"
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
cp "$ICNS_PATH" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>SUFeedURL</key>
    <string>$SPARKLE_FEED_URL</string>
    <key>SUPublicEDKey</key>
    <string>$SPARKLE_PUBLIC_ED_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <real>43200</real>
    <key>SUAutomaticallyUpdate</key>
    <true/>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
    <key>SURequireSignedFeed</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>$DISPLAY_NAME shows upcoming events from the calendars you select.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>$DISPLAY_NAME shows upcoming events from the calendars you select.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>$DISPLAY_NAME uses macOS Automation for system appearance and Quick Actions such as Lock Screen.</string>
</dict>
</plist>
PLIST

sign_sparkle_component() {
    codesign "${CODESIGN_ARGS[@]}" \
        --preserve-metadata=identifier,entitlements \
        "$1"
}

SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK_DESTINATION/Versions/B"
sign_sparkle_component "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
sign_sparkle_component "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
sign_sparkle_component "$SPARKLE_VERSION_DIR/Autoupdate"
sign_sparkle_component "$SPARKLE_VERSION_DIR/Updater.app"
sign_sparkle_component "$SPARKLE_FRAMEWORK_DESTINATION"

codesign "${CODESIGN_ARGS[@]}" \
    --identifier "$HELPER_BUNDLE_IDENTIFIER" \
    "$MACOS_DIR/$HELPER_NAME"

if [[ -n "$APPLE_TEAM_ID" ]]; then
    if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
        echo "CODESIGN_IDENTITY must name an Apple signing identity when APPLE_TEAM_ID is set." >&2
        exit 1
    fi
    if [[ -z "$PROVISIONING_PROFILE" || ! -f "$PROVISIONING_PROFILE" ]]; then
        echo "PROVISIONING_PROFILE must point to an iCloud-enabled macOS provisioning profile." >&2
        exit 1
    fi

    security cms -D -i "$PROVISIONING_PROFILE" > "$PROFILE_PLIST"
    if [[ "$REQUIRE_STABLE_SIGNING" == "true" ]]; then
        PROFILE_ALL_DEVICES="$(/usr/libexec/PlistBuddy \
            -c 'Print :ProvisionsAllDevices' "$PROFILE_PLIST" 2>/dev/null || echo false)"
        PROFILE_GET_TASK_ALLOW="$(/usr/libexec/PlistBuddy \
            -c 'Print :Entitlements:com.apple.security.get-task-allow' \
            "$PROFILE_PLIST" 2>/dev/null || echo false)"
        if [[ "$PROFILE_ALL_DEVICES" != "true" ]]; then
            echo "Stable release profile must authorize all devices." >&2
            exit 1
        fi
        if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' \
            "$PROFILE_PLIST" >/dev/null 2>&1; then
            echo "Device-bound provisioning profiles are forbidden for stable releases." >&2
            exit 1
        fi
        if [[ "$PROFILE_GET_TASK_ALLOW" == "true" ]]; then
            echo "Debug-enabled provisioning profiles are forbidden for stable releases." >&2
            exit 1
        fi
    fi
    PROFILE_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")"
    PROFILE_APP_IDENTIFIER_PREFIX="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationIdentifierPrefix:0' "$PROFILE_PLIST")"
    if ! PROFILE_APPLICATION_IDENTIFIER="$(/usr/libexec/PlistBuddy \
        -c 'Print :Entitlements:com.apple.application-identifier' \
        "$PROFILE_PLIST" 2>/dev/null)"; then
        PROFILE_APPLICATION_IDENTIFIER="$(/usr/libexec/PlistBuddy \
            -c 'Print :Entitlements:application-identifier' \
            "$PROFILE_PLIST")"
    fi
    EXPECTED_APPLICATION_IDENTIFIER="$PROFILE_APP_IDENTIFIER_PREFIX.$BUNDLE_IDENTIFIER"
    if ! PROFILE_KVSTORE_IDENTIFIER="$(/usr/libexec/PlistBuddy \
        -c 'Print :Entitlements:com.apple.developer.ubiquity-kvstore-identifier' \
        "$PROFILE_PLIST" 2>/dev/null)"; then
        echo "Provisioning profile is missing the iCloud key-value-store entitlement." >&2
        exit 1
    fi
    EXPECTED_KVSTORE_IDENTIFIER="$PROFILE_APP_IDENTIFIER_PREFIX.$BUNDLE_IDENTIFIER"

    if [[ "$PROFILE_TEAM_ID" != "$APPLE_TEAM_ID" ]]; then
        echo "Provisioning profile team $PROFILE_TEAM_ID does not match APPLE_TEAM_ID $APPLE_TEAM_ID." >&2
        exit 1
    fi
    if [[ "$PROFILE_APPLICATION_IDENTIFIER" != "$EXPECTED_APPLICATION_IDENTIFIER" \
        && "$PROFILE_APPLICATION_IDENTIFIER" != "$PROFILE_APP_IDENTIFIER_PREFIX.*" ]]; then
        echo "Provisioning profile does not authorize $BUNDLE_IDENTIFIER." >&2
        exit 1
    fi
    if [[ "$PROFILE_KVSTORE_IDENTIFIER" != "$EXPECTED_KVSTORE_IDENTIFIER" \
        && "$PROFILE_KVSTORE_IDENTIFIER" != "$PROFILE_APP_IDENTIFIER_PREFIX.*" ]]; then
        echo "Provisioning profile does not authorize iCloud KVS for $BUNDLE_IDENTIFIER." >&2
        exit 1
    fi

    cp "$PROVISIONING_PROFILE" "$CONTENTS_DIR/embedded.provisionprofile"
    cat > "$RESOLVED_APP_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.application-identifier</key>
    <string>$EXPECTED_APPLICATION_IDENTIFIER</string>
    <key>com.apple.developer.team-identifier</key>
    <string>$PROFILE_TEAM_ID</string>
    <key>com.apple.developer.ubiquity-kvstore-identifier</key>
    <string>$EXPECTED_APPLICATION_IDENTIFIER</string>
</dict>
</plist>
PLIST
    codesign "${CODESIGN_ARGS[@]}" \
        --entitlements "$RESOLVED_APP_ENTITLEMENTS" \
        "$APP_DIR"
    echo "Built iCloud-enabled $APP_DIR"
else
    codesign "${CODESIGN_ARGS[@]}" "$APP_DIR"
    echo "Built local-only $APP_DIR"
fi

codesign --verify --deep --strict "$APP_DIR"
for localization in en zh-Hans; do
    if [[ ! -f "$RESOURCES_DIR/$localization.lproj/Localizable.strings" \
        || ! -f "$RESOURCES_DIR/$localization.lproj/InfoPlist.strings" ]]; then
        echo "Missing packaged $localization localization resources." >&2
        exit 1
    fi
    plutil -lint "$RESOURCES_DIR/$localization.lproj/Localizable.strings" >/dev/null
    plutil -lint "$RESOURCES_DIR/$localization.lproj/InfoPlist.strings" >/dev/null
done
for resource in \
    solar-terms-1901-2100.json \
    solar-terms-1901-2100.metadata.json; do
    if [[ ! -f "$RESOURCES_DIR/$resource" ]]; then
        echo "Missing packaged calendar resource: $resource" >&2
        exit 1
    fi
done
if ! otool -L "$MACOS_DIR/$APP_NAME" | grep -q '@rpath/Sparkle.framework/'; then
    echo "MenuCue does not link the embedded Sparkle framework through @rpath." >&2
    exit 1
fi
if ! otool -l "$MACOS_DIR/$APP_NAME" | grep -q '@executable_path/../Frameworks'; then
    echo "MenuCue is missing the packaged Frameworks rpath." >&2
    exit 1
fi
