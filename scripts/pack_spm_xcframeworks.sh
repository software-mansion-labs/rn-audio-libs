#!/usr/bin/env bash
# Packs the iOS binaries as one zipped .xcframework per library, the format a Swift Package
# Manager `.binaryTarget(url:checksum:)` downloads. react-native-audio-api's Package.swift pins
# the release tag and the checksums written to checksums.txt.
#
# Each xcframework is named after its library (libopus.xcframework, libavcodec.xcframework, ...):
# CocoaPods links a dynamic xcframework as `-framework <xcframework name>`, and a SwiftPM binary
# target takes the xcframework's name.
#
# Usage: pack_spm_xcframeworks.sh [source_dir] [export_dir]
#   source_dir  holds iphoneos/, iphonesimulator/, macosx/ (static libs), ffmpeg_ios/ and
#               include_ffmpeg/ (default: outputs/)
#   export_dir  receives the <name>.xcframework.zip archives and checksums.txt (default: export/spm/)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
SOURCE_DIR="$(cd "${1:-$ROOT_DIR/outputs}" && pwd)"
EXPORT_DIR="${2:-$ROOT_DIR/export/spm}"

STATIC_LIBS=(libopusfile libopus libogg libvorbis libvorbisenc libvorbisfile)
STATIC_LIB_PLATFORMS=(iphoneos iphonesimulator macosx)
FFMPEG_FRAMEWORKS=(libavcodec libavformat libavutil libswresample)
FFMPEG_HEADERS_NAME="FFmpegHeaders"
MIN_IOS="15.0"

for tool in xcodebuild xcrun zip shasum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: $tool is required" >&2
        exit 1
    fi
done

mkdir -p "$EXPORT_DIR"
EXPORT_DIR="$(cd "$EXPORT_DIR" && pwd)"
rm -f "$EXPORT_DIR"/*.xcframework.zip "$EXPORT_DIR/checksums.txt"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

# Zips <xcframework> with its directory as the archive root, as SwiftPM expects, and records
# the checksum SwiftPM verifies (`swift package compute-checksum` is the same SHA-256).
pack_xcframework() {
    local xcframework="$1"
    local name
    name="$(basename "$xcframework")"
    local archive="$EXPORT_DIR/${name}.zip"

    (cd "$(dirname "$xcframework")" && zip -qry "$archive" "$name")
    echo "${name%.xcframework} $(shasum -a 256 "$archive" | cut -d' ' -f1)" >>"$EXPORT_DIR/checksums.txt"
    echo "Packed $name -> $archive"
}

# Mac Catalyst frameworks use the versioned bundle layout, whose symlinks older release zips
# dropped; SwiftPM extracts the archive as-is, so restore them before packing.
restore_versioned_framework_symlinks() {
    local root="$1"
    find "$root" -path "*/Versions/A" -type d | while read -r version_dir; do
        local framework_dir
        framework_dir="$(cd "${version_dir}/../.." && pwd)"
        local framework_name
        framework_name="$(basename "$framework_dir" .framework)"
        [ -f "${version_dir}/${framework_name}" ] || continue
        (
            cd "$framework_dir"
            ln -sfn A Versions/Current
            ln -sfn "Versions/Current/${framework_name}" "$framework_name"
            [ -d Versions/A/Resources ] && ln -sfn Versions/Current/Resources Resources
            [ -d Versions/A/Headers ] && ln -sfn Versions/Current/Headers Headers
            true
        )
    done
}

# Builds an empty static library for one xcframework slice: <sdk> <output> <target>...
build_stub_library() {
    local sdk="$1"
    local output="$2"
    shift 2
    local objects=()
    local target
    echo "" >"$STAGING_DIR/stub.c"
    for target in "$@"; do
        local object="$STAGING_DIR/stub-${target}.o"
        xcrun --sdk "$sdk" clang -c "$STAGING_DIR/stub.c" -target "$target" -o "$object"
        objects+=("$object")
    done
    # xcrun picks Apple's libtool; a Homebrew GNU libtool earlier on PATH cannot do this.
    xcrun libtool -static -o "$output" "${objects[@]}" 2>/dev/null
}

for lib in "${STATIC_LIBS[@]}"; do
    library_args=()
    for platform in "${STATIC_LIB_PLATFORMS[@]}"; do
        slice="$SOURCE_DIR/$platform/$lib.a"
        if [ ! -f "$slice" ]; then
            echo "Error: missing $slice" >&2
            exit 1
        fi
        library_args+=(-library "$slice")
    done
    xcodebuild -create-xcframework "${library_args[@]}" \
        -output "$STAGING_DIR/${lib}.xcframework" >/dev/null
    pack_xcframework "$STAGING_DIR/${lib}.xcframework"
done

for framework in "${FFMPEG_FRAMEWORKS[@]}"; do
    source="$SOURCE_DIR/ffmpeg_ios/$framework.xcframework"
    if [ ! -d "$source" ]; then
        echo "Error: missing $source" >&2
        exit 1
    fi
    cp -R "$source" "$STAGING_DIR/${framework}.xcframework"
    restore_versioned_framework_symlinks "$STAGING_DIR/${framework}.xcframework"
    pack_xcframework "$STAGING_DIR/${framework}.xcframework"
done

# The FFmpeg frameworks carry no headers. SwiftPM adds a library xcframework slice's Headers/
# to its dependents' include path, so ship them as a header-only xcframework around an empty
# stub library (the pattern React Native uses for ReactNativeHeaders.xcframework).
FFMPEG_HEADERS_DIR="$SOURCE_DIR/include_ffmpeg"
if [ ! -d "$FFMPEG_HEADERS_DIR" ]; then
    echo "Error: missing $FFMPEG_HEADERS_DIR" >&2
    exit 1
fi
mkdir -p "$STAGING_DIR/stubs/iphoneos" "$STAGING_DIR/stubs/iphonesimulator" "$STAGING_DIR/stubs/maccatalyst"
STUB_NAME="lib${FFMPEG_HEADERS_NAME}.a"
build_stub_library iphoneos "$STAGING_DIR/stubs/iphoneos/$STUB_NAME" "arm64-apple-ios${MIN_IOS}"
build_stub_library iphonesimulator "$STAGING_DIR/stubs/iphonesimulator/$STUB_NAME" \
    "arm64-apple-ios${MIN_IOS}-simulator" "x86_64-apple-ios${MIN_IOS}-simulator"
build_stub_library macosx "$STAGING_DIR/stubs/maccatalyst/$STUB_NAME" \
    "arm64-apple-ios${MIN_IOS}-macabi" "x86_64-apple-ios${MIN_IOS}-macabi"
xcodebuild -create-xcframework \
    -library "$STAGING_DIR/stubs/iphoneos/$STUB_NAME" -headers "$FFMPEG_HEADERS_DIR" \
    -library "$STAGING_DIR/stubs/iphonesimulator/$STUB_NAME" -headers "$FFMPEG_HEADERS_DIR" \
    -library "$STAGING_DIR/stubs/maccatalyst/$STUB_NAME" -headers "$FFMPEG_HEADERS_DIR" \
    -output "$STAGING_DIR/${FFMPEG_HEADERS_NAME}.xcframework" >/dev/null
pack_xcframework "$STAGING_DIR/${FFMPEG_HEADERS_NAME}.xcframework"
