#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
cd "$ROOT_DIR"

# Creates an Info.plist file for a given framework:
build_info_plist() {
    local file_path="$1"
    local framework_name="$2"
    local framework_id="$3"

    # Minimum version must be the same we used when building FFmpeg.
    local minimum_version_key="MinimumOSVersion"
    local minimum_os_version="16.0"

    local supported_platforms="iPhoneOS"

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

# Creates framework from a dylib file:
create_framework() {
    local framework_name="$1"
    local ffmpeg_library_path="$2"
    local framework_complete_path="${ffmpeg_library_path}/framework/${framework_name}.framework/${framework_name}"

    # Create framework directory and copy dylib file to this directory:
    mkdir -p "${ffmpeg_library_path}/framework/${framework_name}.framework"
    cp "${ffmpeg_library_path}/lib/${framework_name}.dylib" "${ffmpeg_library_path}/framework/${framework_name}.framework/${framework_name}"

    # Change the shared library identification name, removing version number and 'dylib' extension;
    # \c Frameworks part of the name is needed since this is where frameworks will be installed in
    # an application bundle:
    install_name_tool -id @rpath/${framework_name}.framework/${framework_name} "${framework_complete_path}"

    # Add Info.plist file into the framework directory:
    build_info_plist "${ffmpeg_library_path}/framework/${framework_name}.framework/Info.plist" "${framework_name}" "io.qt.ffmpegkit."${framework_name}
    otool -L "$framework_complete_path" | awk '/\t/ {print $1}' | egrep "$dylib_regex" | while read -r dependency_path; do
        found_name=$(tmp=${dependency_path/*\/}; echo ${tmp/\.*})
        if [ "$found_name" != "$framework_name" ]
        then
            # Change the dependent shared library install name to remove version number and 'dylib' extension:
            install_name_tool -change "$dependency_path" @rpath/${found_name}.framework/${found_name} "${framework_complete_path}"
        fi
    done
}

ffmpeg_libs="libavcodec libavformat libavutil libswresample"

# ============================================================================
# iOS frameworks
# ============================================================================
echo "Creating iOS frameworks..."
for name in $ffmpeg_libs; do
    create_framework $name outputs/ffmpeg/ios/iphoneos
    create_framework $name outputs/ffmpeg/ios/iphonesimulator
done

# Create iOS XCFrameworks:
IOS_OUTPUT_DIR="outputs/ffmpeg/ios"

rm -rf "${IOS_OUTPUT_DIR}/libavcodec.xcframework"
rm -rf "${IOS_OUTPUT_DIR}/libavformat.xcframework"
rm -rf "${IOS_OUTPUT_DIR}/libavutil.xcframework"
rm -rf "${IOS_OUTPUT_DIR}/libswresample.xcframework"

xcodebuild -create-xcframework \
    -framework "${IOS_OUTPUT_DIR}/iphoneos/framework/libavcodec.framework" \
    -framework "${IOS_OUTPUT_DIR}/iphonesimulator/framework/libavcodec.framework" \
    -output "${IOS_OUTPUT_DIR}/libavcodec.xcframework"

xcodebuild -create-xcframework \
    -framework "${IOS_OUTPUT_DIR}/iphoneos/framework/libavformat.framework" \
    -framework "${IOS_OUTPUT_DIR}/iphonesimulator/framework/libavformat.framework" \
    -output "${IOS_OUTPUT_DIR}/libavformat.xcframework"

xcodebuild -create-xcframework \
    -framework "${IOS_OUTPUT_DIR}/iphoneos/framework/libavutil.framework" \
    -framework "${IOS_OUTPUT_DIR}/iphonesimulator/framework/libavutil.framework" \
    -output "${IOS_OUTPUT_DIR}/libavutil.xcframework"

xcodebuild -create-xcframework \
    -framework "${IOS_OUTPUT_DIR}/iphoneos/framework/libswresample.framework" \
    -framework "${IOS_OUTPUT_DIR}/iphonesimulator/framework/libswresample.framework" \
    -output "${IOS_OUTPUT_DIR}/libswresample.xcframework"

echo "iOS XCFrameworks created!"

# ============================================================================
# macOS frameworks
# ============================================================================
if [ -d "outputs/ffmpeg/macos/fat/lib" ]; then
    echo "Creating macOS frameworks..."
    for name in $ffmpeg_libs; do
        create_framework $name outputs/ffmpeg/macos/fat
    done

    # Create macOS XCFrameworks:
    MACOS_OUTPUT_DIR="outputs/ffmpeg/macos"

    rm -rf "${MACOS_OUTPUT_DIR}/libavcodec.xcframework"
    rm -rf "${MACOS_OUTPUT_DIR}/libavformat.xcframework"
    rm -rf "${MACOS_OUTPUT_DIR}/libavutil.xcframework"
    rm -rf "${MACOS_OUTPUT_DIR}/libswresample.xcframework"

    xcodebuild -create-xcframework \
        -framework "${MACOS_OUTPUT_DIR}/fat/framework/libavcodec.framework" \
        -output "${MACOS_OUTPUT_DIR}/libavcodec.xcframework"

    xcodebuild -create-xcframework \
        -framework "${MACOS_OUTPUT_DIR}/fat/framework/libavformat.framework" \
        -output "${MACOS_OUTPUT_DIR}/libavformat.xcframework"

    xcodebuild -create-xcframework \
        -framework "${MACOS_OUTPUT_DIR}/fat/framework/libavutil.framework" \
        -output "${MACOS_OUTPUT_DIR}/libavutil.xcframework"

    xcodebuild -create-xcframework \
        -framework "${MACOS_OUTPUT_DIR}/fat/framework/libswresample.framework" \
        -output "${MACOS_OUTPUT_DIR}/libswresample.xcframework"

    echo "macOS XCFrameworks created!"
else
    echo "Skipping macOS frameworks (outputs/ffmpeg/macos/fat/lib not found)"
fi

# ============================================================================
# Mac Catalyst frameworks
# ============================================================================
if [ -d "outputs/ffmpeg/catalyst/fat/lib" ]; then
    echo "Creating Mac Catalyst frameworks..."
    for name in $ffmpeg_libs; do
        create_framework $name outputs/ffmpeg/catalyst/fat
    done

    # Create Catalyst XCFrameworks:
    CATALYST_OUTPUT_DIR="outputs/ffmpeg/catalyst"

    rm -rf "${CATALYST_OUTPUT_DIR}/libavcodec.xcframework"
    rm -rf "${CATALYST_OUTPUT_DIR}/libavformat.xcframework"
    rm -rf "${CATALYST_OUTPUT_DIR}/libavutil.xcframework"
    rm -rf "${CATALYST_OUTPUT_DIR}/libswresample.xcframework"

    xcodebuild -create-xcframework \
        -framework "${CATALYST_OUTPUT_DIR}/fat/framework/libavcodec.framework" \
        -output "${CATALYST_OUTPUT_DIR}/libavcodec.xcframework"

    xcodebuild -create-xcframework \
        -framework "${CATALYST_OUTPUT_DIR}/fat/framework/libavformat.framework" \
        -output "${CATALYST_OUTPUT_DIR}/libavformat.xcframework"

    xcodebuild -create-xcframework \
        -framework "${CATALYST_OUTPUT_DIR}/fat/framework/libavutil.framework" \
        -output "${CATALYST_OUTPUT_DIR}/libavutil.xcframework"

    xcodebuild -create-xcframework \
        -framework "${CATALYST_OUTPUT_DIR}/fat/framework/libswresample.framework" \
        -output "${CATALYST_OUTPUT_DIR}/libswresample.xcframework"

    echo "Mac Catalyst XCFrameworks created!"
else
    echo "Skipping Mac Catalyst frameworks (outputs/ffmpeg/catalyst/fat/lib not found)"
fi

echo "All XCFrameworks created!"




