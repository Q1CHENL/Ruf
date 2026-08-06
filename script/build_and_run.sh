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
PERFORMANCE_LOG="$HOME/Library/Logs/$APP_NAME/performance.log"
SELF_SIGNED_IDENTITY_NAME="Ruf Release Code Signing"
SELF_SIGNED_IDENTITY_SHA1="979E44A42CA7D82F7C73198B826E5D469C4021A9"
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
    local output_path="${1:-$APP_DISK_IMAGE}"
    local working_directory
    local image_source
    local candidate_disk_image
    working_directory="$(mktemp -d)"
    image_source="$working_directory/source"
    candidate_disk_image="$working_directory/$APP_NAME.dmg"

    (
        trap 'rm -rf "$working_directory"' EXIT
        mkdir -p "$image_source"

        /usr/bin/ditto \
            --norsrc \
            "$APP_BUNDLE" \
            "$image_source/$APP_NAME.app"
        ln -s /Applications "$image_source/Applications"

        /usr/sbin/diskutil image create from \
            --format UDZO \
            --volumeName "$APP_NAME" \
            "$image_source" \
            "$candidate_disk_image"

        /bin/mv -f "$candidate_disk_image" "$output_path"
    )
}

sign_for_local_use() {
    # TCC stores the designated requirement, so signing with a stable identity
    # lets an Accessibility approval survive rebuilds. An ad-hoc signature is
    # identified by its code directory hash instead, which every build changes,
    # revoking the approval. Fall back to ad-hoc where the identity is absent,
    # such as CI. The hardened runtime stays off: self-signed bundles are not
    # launchable with it.
    local identity="${RUF_LOCAL_CODESIGN_IDENTITY:-$SELF_SIGNED_IDENTITY_SHA1}"

    if [[ "$identity" != "-" ]] && ! /usr/bin/security find-identity \
        -p codesigning -v | /usr/bin/grep -F "$identity" >/dev/null; then
        identity="-"
    fi

    /usr/bin/codesign \
        --force \
        --sign "$identity" \
        --identifier "$BUNDLE_ID" \
        "$APP_BUNDLE"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
}

require_codesigning_identity() {
    local identity="$1"
    local description="${2:-$identity}"

    if [[ -z "$identity" || "$identity" == "-" ]]; then
        echo "A persistent code-signing identity is required" >&2
        return 1
    fi
    if ! /usr/bin/security find-identity -p codesigning -v \
        | /usr/bin/grep -F "$identity" >/dev/null; then
        echo "Code-signing identity is not available in the current Keychain: $description" >&2
        return 1
    fi
}

require_notarized_release_environment() {
    local identity="${RUF_DEVELOPER_ID_APPLICATION:-}"
    local notary_profile="${RUF_NOTARY_PROFILE:-}"

    if [[ "$identity" != "Developer ID Application:"* ]]; then
        echo "RUF_DEVELOPER_ID_APPLICATION must name a Developer ID Application identity" >&2
        return 1
    fi
    if [[ -z "$notary_profile" ]]; then
        echo "RUF_NOTARY_PROFILE must name a notarytool Keychain profile" >&2
        return 1
    fi
    require_codesigning_identity "$identity"
}

sign_application_for_distribution() {
    local identity="$1"
    local release_kind="$2"
    local sparkle_version="$SPARKLE_FRAMEWORK/Versions/B"
    local arguments=(
        --force
        --sign "$identity"
    )

    case "$release_kind" in
        self-signed)
            ;;
        notarized)
            arguments+=(--options runtime --timestamp)
            ;;
        *)
            echo "Unknown release kind: $release_kind" >&2
            return 2
            ;;
    esac

    /usr/bin/codesign "${arguments[@]}" \
        "$sparkle_version/XPCServices/Installer.xpc"
    /usr/bin/codesign "${arguments[@]}" \
        --preserve-metadata=entitlements \
        "$sparkle_version/XPCServices/Downloader.xpc"
    /usr/bin/codesign "${arguments[@]}" "$sparkle_version/Autoupdate"
    /usr/bin/codesign "${arguments[@]}" "$sparkle_version/Updater.app"
    /usr/bin/codesign "${arguments[@]}" "$SPARKLE_FRAMEWORK"
    /usr/bin/codesign "${arguments[@]}" \
        --identifier "$BUNDLE_ID" \
        "$APP_BUNDLE"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
}

sign_disk_image() {
    local disk_image="$1"
    local identity="$2"
    local release_kind="$3"
    local arguments=(
        --force
        --sign "$identity"
    )

    case "$release_kind" in
        self-signed)
            ;;
        notarized)
            arguments+=(--timestamp)
            ;;
        *)
            echo "Unknown release kind: $release_kind" >&2
            return 2
            ;;
    esac

    /usr/bin/codesign "${arguments[@]}" "$disk_image"
}

notarize_application() {
    local working_directory
    local archive_path
    working_directory="$(mktemp -d)"
    archive_path="$working_directory/$APP_NAME.zip"

    (
        trap 'rm -rf "$working_directory"' EXIT

        /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$archive_path"
        /usr/bin/xcrun notarytool submit "$archive_path" \
            --keychain-profile "$RUF_NOTARY_PROFILE" \
            --wait
    )

    /usr/bin/xcrun stapler staple "$APP_BUNDLE"
    /usr/bin/xcrun stapler validate "$APP_BUNDLE"
    /usr/sbin/spctl -a -t exec -vv "$APP_BUNDLE"
}

notarize_disk_image() {
    local disk_image="$1"

    /usr/bin/xcrun notarytool submit "$disk_image" \
        --keychain-profile "$RUF_NOTARY_PROFILE" \
        --wait
    /usr/bin/xcrun stapler staple "$disk_image"
    /usr/bin/xcrun stapler validate "$disk_image"
    /usr/bin/codesign --verify --verbose=2 "$disk_image"
    /usr/sbin/spctl -a -t open \
        --context context:primary-signature \
        -vv "$disk_image"
}

release_signing_kind() {
    local bundle="$1"
    local requirement
    local requirement_uppercase
    local self_signed_requirement
    requirement="$(/usr/bin/codesign -d -r- "$bundle" 2>&1)"
    requirement_uppercase="$(
        /usr/bin/printf '%s' "$requirement" \
            | /usr/bin/tr '[:lower:]' '[:upper:]'
    )"
    self_signed_requirement="CERTIFICATE LEAF = H\"$SELF_SIGNED_IDENTITY_SHA1\""

    if [[ "$requirement" != *"identifier \"$BUNDLE_ID\""* ]]; then
        echo "Release app has the wrong signing identifier" >&2
        echo "$requirement" >&2
        return 1
    fi

    if [[ "$requirement_uppercase" == *"$self_signed_requirement"* ]]; then
        echo "self-signed"
    elif [[ "$requirement" == *"anchor apple generic"* \
        && "$requirement" == *"certificate leaf"* ]]; then
        echo "developer-id"
    else
        echo "Release app must use Ruf's pinned self-signed identity or Developer ID" >&2
        echo "$requirement" >&2
        return 1
    fi
}

verify_release_runtime_policy() {
    local signing_kind="$1"
    local signature_details
    signature_details="$(
        /usr/bin/codesign -d --verbose=4 "$APP_BUNDLE" 2>&1
    )"

    case "$signing_kind" in
        self-signed)
            if [[ "$signature_details" == *"(runtime)"* ]]; then
                echo "Self-signed releases must not enable the hardened runtime" >&2
                return 1
            fi
            ;;
        developer-id)
            if [[ "$signature_details" != *"(runtime)"* ]]; then
                echo "Developer ID releases must enable the hardened runtime" >&2
                return 1
            fi
            ;;
        *)
            echo "Unknown signing kind: $signing_kind" >&2
            return 2
            ;;
    esac
}

verify_signed_release_artifacts() {
    local signing_kind

    /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    /usr/bin/codesign --verify --verbose=2 "$APP_DISK_IMAGE"
    signing_kind="$(release_signing_kind "$APP_BUNDLE")"
    verify_release_runtime_policy "$signing_kind"
}

verify_notarized_release_artifacts() {
    verify_signed_release_artifacts
    /usr/bin/xcrun stapler validate "$APP_BUNDLE"
    /usr/bin/xcrun stapler validate "$APP_DISK_IMAGE"
    /usr/sbin/spctl -a -t exec -vv "$APP_BUNDLE"
    /usr/sbin/spctl -a -t open \
        --context context:primary-signature \
        -vv "$APP_DISK_IMAGE"
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
    local appcast_path="$DIST_DIR/appcast.xml"
    local signing_kind
    local staging_directory
    local version

    if [[ ! -f "$APP_CONTENTS/Info.plist" || ! -f "$APP_DISK_IMAGE" ]]; then
        echo "Release artifacts are missing; run a release mode first" >&2
        return 1
    fi

    signing_kind="$(release_signing_kind "$APP_BUNDLE")"
    if [[ "$signing_kind" == developer-id ]]; then
        verify_notarized_release_artifacts
    else
        verify_signed_release_artifacts
    fi

    version="$(/usr/libexec/PlistBuddy \
        -c "Print :CFBundleShortVersionString" \
        "$APP_CONTENTS/Info.plist")"
    staging_directory="$(mktemp -d "$DIST_DIR/.appcast.XXXXXX")"

    (
        trap 'rm -rf "$staging_directory"' EXIT

        /usr/bin/ditto \
            --norsrc \
            "$APP_DISK_IMAGE" \
            "$staging_directory/$APP_NAME.dmg"

        if [[ -f "$appcast_path" ]]; then
            /usr/bin/ditto \
                --norsrc \
                "$appcast_path" \
                "$staging_directory/appcast.xml"
        fi

        "$SPARKLE_TOOLS/generate_appcast" \
            --account "$SPARKLE_KEY_ACCOUNT" \
            --download-url-prefix "$REPOSITORY_URL/releases/download/v$version/" \
            --link "$REPOSITORY_URL" \
            "$staging_directory"

        if [[ ! -s "$staging_directory/appcast.xml" ]]; then
            echo "Sparkle did not generate an appcast" >&2
            exit 1
        fi

        /bin/mv -f "$staging_directory/appcast.xml" "$appcast_path"
    )
}

assemble_app() {
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

}

package_for_local_use() {
    local configuration="$1"
    shift

    assemble_app "$configuration" "$@"
    sign_for_local_use
    create_disk_image
    rm -f "$DIST_DIR/$APP_NAME.zip"
}

package_for_distribution() (
    local release_kind="$1"
    local final_app_bundle="$APP_BUNDLE"
    local final_disk_image="$APP_DISK_IMAGE"
    local identity
    local release_directory
    local previous_app_bundle
    local previous_app_moved=false
    local new_app_published=false

    case "$release_kind" in
        self-signed)
            identity="$SELF_SIGNED_IDENTITY_SHA1"
            require_codesigning_identity "$identity" "$SELF_SIGNED_IDENTITY_NAME"
            ;;
        notarized)
            identity="${RUF_DEVELOPER_ID_APPLICATION:-}"
            require_notarized_release_environment
            ;;
        *)
            echo "Unknown release kind: $release_kind" >&2
            return 2
            ;;
    esac

    # The staging directory lives beside the artifacts, and a release from a
    # fresh clone reaches this point before anything has created dist/.
    mkdir -p "$DIST_DIR"
    release_directory="$(mktemp -d "$DIST_DIR/.release.XXXXXX")"
    previous_app_bundle="$release_directory/previous-$APP_NAME.app"

    cleanup_distribution() {
        local status=$?

        if [[ $status -ne 0 ]]; then
            if [[ "$new_app_published" == true ]]; then
                rm -rf "$final_app_bundle"
            fi
            if [[ "$previous_app_moved" == true \
                && -e "$previous_app_bundle" ]]; then
                /bin/mv "$previous_app_bundle" "$final_app_bundle"
            fi
        fi

        rm -rf "$release_directory"
        trap - EXIT
        exit "$status"
    }
    trap cleanup_distribution EXIT

    APP_BUNDLE="$release_directory/$APP_NAME.app"
    APP_DISK_IMAGE="$release_directory/$APP_NAME.dmg"
    APP_CONTENTS="$APP_BUNDLE/Contents"
    APP_MACOS="$APP_CONTENTS/MacOS"
    APP_BINARY="$APP_MACOS/$APP_NAME"
    APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
    APP_RESOURCES="$APP_CONTENTS/Resources"
    SPARKLE_FRAMEWORK="$APP_FRAMEWORKS/Sparkle.framework"

    assemble_app release "${UNIVERSAL_ARCHS[@]}"
    sign_application_for_distribution "$identity" "$release_kind"
    if [[ "$release_kind" == notarized ]]; then
        notarize_application
    fi
    create_disk_image
    sign_disk_image "$APP_DISK_IMAGE" "$identity" "$release_kind"
    if [[ "$release_kind" == notarized ]]; then
        notarize_disk_image "$APP_DISK_IMAGE"
        verify_notarized_release_artifacts
    else
        verify_signed_release_artifacts
    fi

    if [[ -e "$final_app_bundle" ]]; then
        /bin/mv "$final_app_bundle" "$previous_app_bundle"
        previous_app_moved=true
    fi
    /bin/mv "$APP_BUNDLE" "$final_app_bundle"
    new_app_published=true
    /bin/mv -f "$APP_DISK_IMAGE" "$final_disk_image"

    new_app_published=false
    previous_app_moved=false
    rm -rf "$previous_app_bundle"
    rm -f "$DIST_DIR/$APP_NAME.zip"
)

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

prepare_debug_app() {
    stop_running_app
    package_for_local_use debug
}

launch_debug_app() {
    prepare_debug_app
    open_app
}

case "$MODE" in
    package)
        package_for_local_use release "${UNIVERSAL_ARCHS[@]}"
        ;;
    release-self-signed)
        package_for_distribution self-signed
        ;;
    release-notarized)
        package_for_distribution notarized
        ;;
    appcast)
        generate_appcast
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
        # Scope the opt-in to this session. The app reads the preference once at
        # launch, so clearing it on exit disarms the next ordinary launch
        # without disturbing the run being measured.
        /usr/bin/defaults write "$BUNDLE_ID" RufPerformanceLogging -bool YES
        trap '/usr/bin/defaults delete "$BUNDLE_ID" \
            RufPerformanceLogging 2>/dev/null || true' EXIT
        launch_debug_app
        /usr/bin/tail -n 0 -F "$PERFORMANCE_LOG"
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
        echo "usage: $0 [run|--package|--release-self-signed|--release-notarized|--appcast|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
