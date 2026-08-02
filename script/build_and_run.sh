#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
MODE="${MODE#--}"
APP_NAME="Ruf"
BUNDLE_ID="com.qichen.ruf"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_ARCHIVE="$DIST_DIR/$APP_NAME.zip"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
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

archive_app() {
    rm -f "$APP_ARCHIVE"
    /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ARCHIVE"
}

package_app() {
    local configuration="$1"
    shift

    local build_arguments=(-c "$configuration" "$@")

    swift build "${build_arguments[@]}"

    local build_binary
    build_binary="$(swift build "${build_arguments[@]}" --show-bin-path)/$APP_NAME"

    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_MACOS"
    cp "$build_binary" "$APP_BINARY"
    cp "$ROOT_DIR/Resources/Info.plist" "$APP_CONTENTS/Info.plist"
    chmod +x "$APP_BINARY"
    xattr -cr "$APP_BUNDLE"

    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    archive_app
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
