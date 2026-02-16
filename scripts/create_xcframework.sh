#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
cd "$ROOT_DIR"

IOS_MIN_VERSION="${IOS_MIN_VERSION:-15.1}"
MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-11.0}"

# Creates an Info.plist file for a given framework:
build_info_plist() {
    local file_path="$1"
    local framework_name="$2"
    local framework_id="$3"
    local platform="$4"

    local minimum_version_key
    local minimum_os_version
    local supported_platforms

    if [[ "$platform" == "macos" || "$platform" == "catalyst" ]]; then
        minimum_version_key="LSMinimumSystemVersion"
        minimum_os_version="${MACOS_MIN_VERSION}"
        supported_platforms="MacOSX"
    else
        minimum_version_key="MinimumOSVersion"
        minimum_os_version="${IOS_MIN_VERSION}"
        supported_platforms="iPhoneOS"
    fi

    info_plist="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${framework_name}</string>
    <key>CFBundleIdentifier</key>
    <string>${framework_id}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${framework_name}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>7.0.2</string>
    <key>CFBundleVersion</key>
    <string>7.0.2</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>${minimum_version_key}</key>
    <string>${minimum_os_version}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>${supported_platforms}</string>
    </array>
    <key>NSPrincipalClass</key>
    <string></string>
</dict>
</plist>"
    echo $info_plist | tee ${file_path} 1>/dev/null
}

dylib_regex="^@rpath/.*\.dylib$"

# Fixes a flat framework bundle into macOS/Catalyst versioned structure.
fix_macos_framework_bundle_structure() {
    local framework_path="$1"
    local framework_name="$2"

    if [ -d "$framework_path" ] && [ -f "$framework_path/Info.plist" ] && [ ! -d "$framework_path/Versions" ]; then
        echo "Fixing ${framework_name}.framework bundle structure..."

        mkdir -p "$framework_path/Versions/A/Resources"
        mv "$framework_path/Info.plist" "$framework_path/Versions/A/Resources/"
        mv "$framework_path/$framework_name" "$framework_path/Versions/A/"
        if [ -f "$framework_path/LICENSE" ]; then
            mv "$framework_path/LICENSE" "$framework_path/Versions/A/"
        fi

        ln -sfn A "$framework_path/Versions/Current"
        ln -sfn "Versions/Current/$framework_name" "$framework_path/$framework_name"
        ln -sfn Versions/Current/Resources "$framework_path/Resources"

        echo "${framework_name}.framework structure fixed"
    fi
}

# Creates framework from a dylib file:
create_framework() {
    local framework_name="$1"
    local ffmpeg_library_path="$2"
    local platform="$3"
    local framework_root="${ffmpeg_library_path}/framework/${framework_name}.framework"
    local framework_complete_path="${ffmpeg_library_path}/framework/${framework_name}.framework/${framework_name}"

    # Create framework directory and copy dylib file to this directory:
    mkdir -p "${framework_root}"
    cp "${ffmpeg_library_path}/lib/${framework_name}.dylib" "${framework_root}/${framework_name}"

    # Change the shared library identification name, removing version number and 'dylib' extension;
    # \c Frameworks part of the name is needed since this is where frameworks will be installed in
    # an application bundle:
    install_name_tool -id @rpath/${framework_name}.framework/${framework_name} "${framework_complete_path}"

    # Add Info.plist file into the framework directory:
    build_info_plist "${framework_root}/Info.plist" "${framework_name}" "io.qt.ffmpegkit."${framework_name} "${platform}"
    otool -L "$framework_complete_path" | awk '/\t/ {print $1}' | egrep "$dylib_regex" | while read -r dependency_path; do
        found_name=$(tmp=${dependency_path/*\/}; echo ${tmp/\.*})
        if [ "$found_name" != "$framework_name" ]
        then
            # Change the dependent shared library install name to remove version number and 'dylib' extension:
            install_name_tool -change "$dependency_path" @rpath/${found_name}.framework/${found_name} "${framework_complete_path}"
        fi
    done

    if [[ "$platform" == "macos" || "$platform" == "catalyst" ]]; then
        fix_macos_framework_bundle_structure "${framework_root}" "${framework_name}"
    fi
}

ffmpeg_libs="libavcodec libavformat libavutil libswresample"

# Creates a set of XCFrameworks from one or more framework roots.
create_xcframework_set() {
    local output_dir="$1"
    shift
    local framework_roots=("$@")

    mkdir -p "${output_dir}"

    for name in $ffmpeg_libs; do
        rm -rf "${output_dir}/${name}.xcframework"

        local create_cmd=(xcodebuild -create-xcframework)
        local framework_root
        for framework_root in "${framework_roots[@]}"; do
            create_cmd+=(-framework "${framework_root}/${name}.framework")
        done
        create_cmd+=(-output "${output_dir}/${name}.xcframework")

        "${create_cmd[@]}"
    done

    echo "XCFrameworks created at ${output_dir}"
}

# ============================================================================
# iOS frameworks
# ============================================================================
echo "Creating iOS frameworks..."
for name in $ffmpeg_libs; do
    create_framework $name outputs/ffmpeg/ios/iphoneos ios
    create_framework $name outputs/ffmpeg/ios/iphonesimulator ios
done

# ============================================================================
# Mac Catalyst frameworks
# ============================================================================
if [ ! -d "outputs/ffmpeg/catalyst/fat/lib" ]; then
    echo "Error: outputs/ffmpeg/catalyst/fat/lib not found; Catalyst frameworks are required for iOS XCFramework set."
    exit 1
fi

echo "Creating Mac Catalyst frameworks..."
for name in $ffmpeg_libs; do
    create_framework $name outputs/ffmpeg/catalyst/fat catalyst
done

echo "Creating single iOS XCFramework set (device + simulator + catalyst)..."
create_xcframework_set "outputs/ffmpeg/ios" \
    "outputs/ffmpeg/ios/iphoneos/framework" \
    "outputs/ffmpeg/ios/iphonesimulator/framework" \
    "outputs/ffmpeg/catalyst/fat/framework"

echo "All XCFrameworks created in outputs/ffmpeg/ios"

