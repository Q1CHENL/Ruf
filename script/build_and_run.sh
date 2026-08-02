#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
MODE="${MODE#--}"
APP_NAME="Ruf"
BUNDLE_ID="com.qichen.ruf"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_DISK_IMAGE="$DIST_DIR/$APP_NAME.dmg"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_ICON_SOURCE="$ROOT_DIR/Resources/AppIcon/$APP_NAME.icon"
SPARKLE_FRAMEWORK="$APP_FRAMEWORKS/Sparkle.framework"
SPARKLE_TOOLS="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
SPARKLE_KEY_ACCOUNT="$BUNDLE_ID"
REPOSITORY_URL="https://github.com/Q1CHENL/Ruf"
UNIVERSAL_ARCHS=(--arch arm64 --arch x86_64)

stop_running_app() {
    local pid
    local process_path

    while IFS= read -r pid; do
        process_path="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
        if [[ "$process_path" == "$APP_BINARY" ]]; then
            kill "$pid"
        fi
    done < <(pgrep -x "$APP_NAME" || true)
}

create_disk_image() {
    local staging_directory
    staging_directory="$(mktemp -d)"

    (
        trap 'rm -rf "$staging_directory"' EXIT

        /usr/bin/ditto \
            --norsrc \
            "$APP_BUNDLE" \
            "$staging_directory/$APP_NAME.app"
        ln -s /Applications "$staging_directory/Applications"

        rm -f "$APP_DISK_IMAGE" "$DIST_DIR/$APP_NAME.zip"
        /usr/sbin/diskutil image create from \
            --format UDZO \
            --volumeName "$APP_NAME" \
            "$staging_directory" \
            "$APP_DISK_IMAGE"
    )
}

compile_app_icon() {
    local generated_info_plist="$APP_CONTENTS/assetcatalog_generated_info.plist"
    local minimum_system_version
    minimum_system_version="$(/usr/libexec/PlistBuddy \
        -c "Print :LSMinimumSystemVersion" \
        "$APP_CONTENTS/Info.plist")"

    /usr/bin/xcrun actool \
        --compile "$APP_RESOURCES" \
        --platform macosx \
        --minimum-deployment-target "$minimum_system_version" \
        --app-icon "$APP_NAME" \
        --output-partial-info-plist "$generated_info_plist" \
        --output-format human-readable-text \
        --warnings \
        --notices \
        "$APP_ICON_SOURCE"

    /usr/libexec/PlistBuddy \
        -c "Merge $generated_info_plist" \
        "$APP_CONTENTS/Info.plist"
    rm "$generated_info_plist"
}

generate_appcast() {
    local version
    version="$(/usr/libexec/PlistBuddy \
        -c "Print :CFBundleShortVersionString" \
        "$APP_CONTENTS/Info.plist")"

    rm -f "$DIST_DIR/appcast.xml"
    "$SPARKLE_TOOLS/generate_appcast" \
        --account "$SPARKLE_KEY_ACCOUNT" \
        --download-url-prefix "$REPOSITORY_URL/releases/download/v$version/" \
        --link "$REPOSITORY_URL" \
        "$DIST_DIR"
}

package_app() {
    local configuration="$1"
    shift

    local build_arguments=(-c "$configuration" "$@")

    swift build "${build_arguments[@]}"

    local build_directory
    build_directory="$(swift build "${build_arguments[@]}" --show-bin-path)"

    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES"
    cp "$build_directory/$APP_NAME" "$APP_BINARY"
    /usr/bin/ditto \
        "$build_directory/Sparkle.framework" \
        "$SPARKLE_FRAMEWORK"
    cp "$ROOT_DIR/Resources/Info.plist" "$APP_CONTENTS/Info.plist"
    compile_app_icon
    chmod +x "$APP_BINARY"
    install_name_tool \
        -add_rpath "@executable_path/../Frameworks" \
        "$APP_BINARY"
    xattr -cr "$APP_BUNDLE"

    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    create_disk_image

    if [[ "$configuration" == "release" ]]; then
        generate_appcast
    fi
}

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

prepare_debug_app() {
    stop_running_app
    package_app debug
}

launch_debug_app() {
    prepare_debug_app
    open_app
}

case "$MODE" in
    package)
        package_app release "${UNIVERSAL_ARCHS[@]}"
        ;;
    run)
        launch_debug_app
        ;;
    debug)
        prepare_debug_app
        lldb -- "$APP_BINARY"
        ;;
    logs)
        launch_debug_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    telemetry)
        launch_debug_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    verify)
        launch_debug_app
        for _ in {1..20}; do
            if pgrep -x "$APP_NAME" >/dev/null; then
                exit 0
            fi
            sleep 0.1
        done
        echo "$APP_NAME did not stay running" >&2
        exit 1
        ;;
    *)
        echo "usage: $0 [run|--package|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
