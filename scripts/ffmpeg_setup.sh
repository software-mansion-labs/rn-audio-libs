#!/bin/bash

# FFmpeg Mobile Architecture Build Script
# Builds shared ffmpeg binaries for iOS, macOS, Mac Catalyst, and Android architectures
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
SOURCES_DIR="$ROOT_DIR/sources"
SOURCE_DIR="$SOURCES_DIR/ffmpeg"
BUILD_DIR="$ROOT_DIR/build/intermediate/ffmpeg"
OUTPUT_DIR="$BUILD_DIR/output"
FFMPEG_INCLUDE_OUTPUT_DIR="$ROOT_DIR/outputs/include_ffmpeg"
FFMPEG_IOS_OUTPUT_DIR="$ROOT_DIR/outputs/ffmpeg_ios"
FFMPEG_ANDROID_OUTPUT_DIR="$ROOT_DIR/outputs/jniLibs"
SHARED_INCLUDE_OUTPUT_DIR="$ROOT_DIR/outputs/include"

# Read FFmpeg version from configs.json
CONFIG_FILE="$ROOT_DIR/configs.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: configs.json not found at $CONFIG_FILE"
    exit 1
fi

FFMPEG_VERSION=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['ffmpeg']['version'])")

if [ -z "$FFMPEG_VERSION" ]; then
    echo "Error: Could not read ffmpeg version from configs.json"
    exit 1
fi

IOS_MIN_VERSION="${IOS_MIN_VERSION:-15.1}"
MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-11.0}"

mkdir -p "${BUILD_DIR}"
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${FFMPEG_INCLUDE_OUTPUT_DIR}"
mkdir -p "${FFMPEG_IOS_OUTPUT_DIR}"
mkdir -p "${FFMPEG_ANDROID_OUTPUT_DIR}"
mkdir -p "${SHARED_INCLUDE_OUTPUT_DIR}"

AVUTIL_VERSION="60.8.100"
AVCODEC_VERSION="62.11.100"
AVFORMAT_VERSION="62.3.100"
SWRRESAMPLE_VERSION="6.1.100"

# ============================================================================
# DOWNLOAD FFMPEG SOURCE
# ============================================================================

download_ffmpeg() {
    echo "=== Downloading FFmpeg v$FFMPEG_VERSION ==="

    mkdir -p "$SOURCES_DIR"

    FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
    FFMPEG_TARBALL="$SOURCES_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz"

    if [ -d "$SOURCE_DIR" ]; then
        echo "Removing existing ffmpeg directory..."
        rm -rf "$SOURCE_DIR"
    fi

    if [ ! -f "$FFMPEG_TARBALL" ]; then
        echo "Downloading FFmpeg source from $FFMPEG_URL..."
        curl -L -o "$FFMPEG_TARBALL" "$FFMPEG_URL"
    else
        echo "Using cached tarball: $FFMPEG_TARBALL"
    fi

    echo "Extracting FFmpeg source..."
    tar -xJf "$FFMPEG_TARBALL" -C "$SOURCES_DIR"

    mv "$SOURCES_DIR/ffmpeg-${FFMPEG_VERSION}" "$SOURCE_DIR"

    echo "=== FFmpeg v$FFMPEG_VERSION downloaded to $SOURCE_DIR ==="
}

COMMON_CONFIG="
--disable-programs
--disable-doc
--disable-htmlpages
--disable-manpages
--disable-podpages
--disable-txtpages
--disable-avdevice
--disable-swscale
--disable-avfilter
--disable-protocols
--disable-devices
--disable-filters
--disable-static
--disable-debug
--disable-optimizations
--disable-everything
--disable-audiotoolbox
--disable-videotoolbox
--disable-hwaccels
--disable-x86asm
--disable-inline-asm
--disable-xlib
--disable-libxcb
--disable-sdl2
--enable-shared
--enable-small
--enable-protocol=https,tls,tcp,http,udp,file
--enable-demuxer=hls,mov,mp3
--enable-parser=aac
--enable-decoder=aac,mp3,flac,alac
--enable-encoder=aac,mp3,flac,pcm_s16le
--enable-muxer=wav,mp4,flac,caf
--enable-pic
"

build_arch() {
    local ARCH=$1
    local PLATFORM=$2
    local CC=$3
    local CXX=$4
    local CFLAGS=$5
    local LDFLAGS=$6
    local EXTRA_CONFIG=$7
    
    if [[ ${PLATFORM} == "android" ]]; then
        PLATFORM_NAME="android"
        if [[ ${ARCH} == "aarch64" ]]; then
            ARCH_NAME="arm64-v8a"
        elif [[ ${ARCH} == "armv7a" ]]; then
            ARCH_NAME="armeabi-v7a"
        else
            ARCH_NAME=${ARCH}
        fi
    elif [[ ${PLATFORM} == "darwin" ]]; then
        PLATFORM_NAME="ios"
        ARCH_NAME="iphoneos"
    elif [[ ${PLATFORM} == "darwinsim" ]]; then
        PLATFORM_NAME="ios"
        if [[ ${ARCH} == "x86_64" ]]; then
            ARCH_NAME="iphonesimulator_x86_64"
        else
            ARCH_NAME="iphonesimulator_arm64"
        fi
    elif [[ ${PLATFORM} == "macos" ]]; then
        PLATFORM_NAME="macos"
        ARCH_NAME="${ARCH}"
    elif [[ ${PLATFORM} == "catalyst" ]]; then
        PLATFORM_NAME="catalyst"
        ARCH_NAME="${ARCH}"
    fi

    echo "Building FFmpeg for ${PLATFORM_NAME} ${ARCH_NAME}..."
    
    SOURCE_PATH="${BUILD_DIR}/ffmpeg-${PLATFORM_NAME}-${ARCH_NAME}-run-$(date +%s)-$$-$RANDOM"
    OUTPUT_PATH="${OUTPUT_DIR}/${PLATFORM_NAME}/${ARCH_NAME}"
    
    mkdir -p "${OUTPUT_PATH}"
    
    echo "Copying source for ${PLATFORM_NAME} ${ARCH_NAME}..."
    cp -r "${SOURCE_DIR}" "${SOURCE_PATH}"
    
    cd "${SOURCE_PATH}"
    
    local TARGET_OS=${PLATFORM}
    if [[ ${PLATFORM} == "darwinsim" || ${PLATFORM} == "macos" || ${PLATFORM} == "catalyst" ]]; then
        TARGET_OS="darwin"
    fi

    echo --enable-cross-compile --arch=${ARCH} --target-os=${TARGET_OS} --cc="${CC}" --cxx="${CXX}" --extra-cflags="${CFLAGS}" --extra-ldflags="${LDFLAGS}" --prefix="${OUTPUT_PATH}" ${COMMON_CONFIG} ${EXTRA_CONFIG}

    # Configure
    ./configure \
        --enable-cross-compile \
        --arch=${ARCH} \
        --target-os=${TARGET_OS} \
        --cc="${CC}" \
        --cxx="${CXX}" \
        --extra-cflags="${CFLAGS}" \
        --extra-ldflags="${LDFLAGS}" \
        --prefix="${OUTPUT_PATH}" \
        ${COMMON_CONFIG} \
        ${EXTRA_CONFIG}
    
    # Build
    make -j10
    make install
    
    echo "Completed ${PLATFORM} ${ARCH}"
    cd - > /dev/null
}

fix_dynamic_linkage() {
    local LIB_PATH=$1
    
    # Get all dependencies that are not system libraries (including the library itself)
    otool -L "${LIB_PATH}" | grep -v "/usr/lib/" | grep -v "/System/" | awk 'NR>1 {print $1}' | while read -r dep; do
        if [[ -n "$dep" ]]; then
            # Extract library name without any version numbers and extension for framework path
            local lib_name=$(basename "$dep" | sed 's/\.dylib$//' | sed 's/\.[0-9][0-9.]*$//')
            local framework_path="@rpath/${lib_name}.framework/${lib_name}"
            echo "Changing dependency: $dep -> $framework_path"
            install_name_tool -change "$dep" "$framework_path" "${LIB_PATH}"
        fi
    done
    
    # Also update the library's own install name to use @rpath with framework structure
    local lib_name=$(basename "${LIB_PATH}" | sed 's/\.dylib$//' | sed 's/\.[0-9][0-9.]*$//')
    local framework_path="@rpath/${lib_name}.framework/${lib_name}"
    echo "Updating install name for $(basename "${LIB_PATH}") -> $framework_path"
    install_name_tool -id "$framework_path" "${LIB_PATH}"
}

sync_ffmpeg_headers() {
    local src_include_dir="${OUTPUT_DIR}/ios/iphoneos/include"
    if [ ! -d "${src_include_dir}" ]; then
        echo "Error: FFmpeg iOS headers not found at ${src_include_dir}"
        exit 1
    fi

    mkdir -p "${FFMPEG_INCLUDE_OUTPUT_DIR}"
    cp -R "${src_include_dir}/." "${FFMPEG_INCLUDE_OUTPUT_DIR}/"
}

postprocess_ffmpeg_headers() {
    if [ ! -d "${FFMPEG_INCLUDE_OUTPUT_DIR}" ]; then
        echo "Skipping FFmpeg header post-processing (${FFMPEG_INCLUDE_OUTPUT_DIR} not found)"
        return
    fi

    rm -f "${FFMPEG_INCLUDE_OUTPUT_DIR}/libavutil/time.h"

    local file
    while IFS= read -r file; do
        perl -pi -e 's/AVMediaType/AVMediaTypeFFmpeg/g' "$file"
    done < <(grep -rl -- "AVMediaType" "${FFMPEG_INCLUDE_OUTPUT_DIR}" || true)
}

sync_ffmpeg_android_libs() {
    local src_root="${OUTPUT_DIR}/android"
    if [ ! -d "${src_root}" ]; then
        echo "Error: FFmpeg Android libs not found at ${src_root}"
        exit 1
    fi

    mkdir -p "${FFMPEG_ANDROID_OUTPUT_DIR}"

    local abi_dir
    for abi_dir in "${src_root}"/*; do
        [ -d "${abi_dir}" ] || continue

        local abi_name
        abi_name="$(basename "${abi_dir}")"
        local src_lib_dir="${abi_dir}/lib"
        local dest_lib_dir="${FFMPEG_ANDROID_OUTPUT_DIR}/${abi_name}"

        [ -d "${src_lib_dir}" ] || continue

        rm -rf "${dest_lib_dir}"
        mkdir -p "${dest_lib_dir}"
        cp -R "${src_lib_dir}/." "${dest_lib_dir}/"
    done
}

sync_openssl_dependency_outputs() {
    local shared_include_src="${OPENSSL_PREBUILT_FOLDER}/include-iphoneos"
    if [ ! -d "${shared_include_src}" ]; then
        shared_include_src="$(find "${OPENSSL_PREBUILT_FOLDER}" -maxdepth 1 -type d -name 'include-*' | head -n 1)"
    fi
    if [ -z "${shared_include_src}" ] || [ ! -d "${shared_include_src}" ]; then
        shared_include_src="${OPENSSL_PREBUILT_FOLDER}/include"
    fi
    if [ -z "${shared_include_src}" ] || [ ! -d "${shared_include_src}" ]; then
        echo "Error: OpenSSL include directory not found under ${OPENSSL_PREBUILT_FOLDER}"
        exit 1
    fi

    # Export only public OpenSSL headers. Internal "crypto/*.h" contains
    # names like crypto/ctype.h that can shadow libc++ headers when include
    # paths are recursive.
    rm -rf "${SHARED_INCLUDE_OUTPUT_DIR}/crypto"
    mkdir -p "${SHARED_INCLUDE_OUTPUT_DIR}/openssl"
    cp -R "${shared_include_src}/openssl/." "${SHARED_INCLUDE_OUTPUT_DIR}/openssl/"

    mkdir -p "${ROOT_DIR}/outputs/iphoneos" "${ROOT_DIR}/outputs/iphonesimulator" "${ROOT_DIR}/outputs/macosx"

    cp "${OPENSSL_PREBUILT_FOLDER}/iphoneos/libcrypto.a" "${ROOT_DIR}/outputs/iphoneos/libcrypto.a"
    cp "${OPENSSL_PREBUILT_FOLDER}/iphoneos/libssl.a" "${ROOT_DIR}/outputs/iphoneos/libssl.a"

    lipo -create \
        "${OPENSSL_PREBUILT_FOLDER}/iphonesimulator/libcrypto.a" \
        "${OPENSSL_PREBUILT_FOLDER}/iphonesimulator-x86_64/libcrypto.a" \
        -output "${ROOT_DIR}/outputs/iphonesimulator/libcrypto.a"
    lipo -create \
        "${OPENSSL_PREBUILT_FOLDER}/iphonesimulator/libssl.a" \
        "${OPENSSL_PREBUILT_FOLDER}/iphonesimulator-x86_64/libssl.a" \
        -output "${ROOT_DIR}/outputs/iphonesimulator/libssl.a"

    lipo -create \
        "${OPENSSL_PREBUILT_FOLDER}/catalyst-arm64/libcrypto.a" \
        "${OPENSSL_PREBUILT_FOLDER}/catalyst-x86_64/libcrypto.a" \
        -output "${ROOT_DIR}/outputs/macosx/libcrypto.a"
    lipo -create \
        "${OPENSSL_PREBUILT_FOLDER}/catalyst-arm64/libssl.a" \
        "${OPENSSL_PREBUILT_FOLDER}/catalyst-x86_64/libssl.a" \
        -output "${ROOT_DIR}/outputs/macosx/libssl.a"

    local abi
    for abi in arm64-v8a armeabi-v7a x86 x86_64; do
        if [ -f "${OPENSSL_PREBUILT_FOLDER}/${abi}/libcrypto.a" ] && [ -f "${OPENSSL_PREBUILT_FOLDER}/${abi}/libssl.a" ]; then
            mkdir -p "${ROOT_DIR}/outputs/android/${abi}"
            cp "${OPENSSL_PREBUILT_FOLDER}/${abi}/libcrypto.a" "${ROOT_DIR}/outputs/android/${abi}/libcrypto.a"
            cp "${OPENSSL_PREBUILT_FOLDER}/${abi}/libssl.a" "${ROOT_DIR}/outputs/android/${abi}/libssl.a"
        fi
    done
}

# Download FFmpeg source if not present
if [ ! -d "${SOURCE_DIR}" ]; then
    download_ffmpeg
fi

# Clean the source directory of any previous builds
cd "${SOURCE_DIR}"
make distclean 2>/dev/null || true
cd - > /dev/null

# Use NDK_ROOT if ANDROID_NDK_ROOT is not set
NDK_PATH="${ANDROID_NDK_ROOT:-$NDK_ROOT}"

API_LEVEL=21

if [ -d "$NDK_PATH" ]; then
    TOOLCHAIN_PATH="${NDK_PATH}/toolchains/llvm/prebuilt"
    export ANDROID_NDK_ROOT=${NDK_PATH}
fi

# Detect host OS for toolchain
if [[ "$OSTYPE" == "darwin"* ]]; then
    HOST_TAG="darwin-x86_64"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    HOST_TAG="linux-x86_64"
fi

if [ -d "$NDK_PATH" ]; then
    TOOLCHAIN="${TOOLCHAIN_PATH}/${HOST_TAG}"
    PATH=$TOOLCHAIN/bin:$PATH
fi

OPENSSL_PREBUILT_FOLDER="${ROOT_DIR}/build/intermediate/openssl-prebuilt"
if [ ! -d "$OPENSSL_PREBUILT_FOLDER" ]; then
    echo "Cloning and building OpenSSL..."
    OPENSSL_SOURCE_DIR="$BUILD_DIR/openssl-src"
    if [ ! -d "$OPENSSL_SOURCE_DIR" ]; then
        git clone https://github.com/openssl/openssl.git "$OPENSSL_SOURCE_DIR"
    fi

    build_openssl_variant() {
        local variant_name="$1"
        local openssl_target="$2"
        local output_subdir="$3"
        local variant_cflags="$4"
        local extra_config="${5:-}"

        local variant_dir="${BUILD_DIR}/openssl-${variant_name}-run-$(date +%s)-$$-$RANDOM"
        cp -R "$OPENSSL_SOURCE_DIR" "$variant_dir"
        cd "$variant_dir"

        if [ -n "$variant_cflags" ]; then
            export CFLAGS="$variant_cflags"
        else
            unset CFLAGS
        fi

        if [ -n "$extra_config" ]; then
            ./Configure "$openssl_target" no-shared no-asm no-tests "$extra_config"
        else
            ./Configure "$openssl_target" no-shared no-asm no-tests
        fi

        make build_libs -j10
        mkdir -p "${OPENSSL_PREBUILT_FOLDER}/${output_subdir}"
        cp libcrypto.a libssl.a "${OPENSSL_PREBUILT_FOLDER}/${output_subdir}"
        local include_dir="${OPENSSL_PREBUILT_FOLDER}/include-${output_subdir}"
        mkdir -p "${include_dir}"
        cp -r include/crypto include/openssl "${include_dir}"
        cd "$ROOT_DIR"
    }

    # ios-arm
    build_openssl_variant "iphoneos" "ios64-xcrun" "iphoneos" "-mios-version-min=${IOS_MIN_VERSION}"

    # arm-simulator
    build_openssl_variant "iphonesimulator-arm64" "iossimulator-arm64-xcrun" "iphonesimulator" "-mios-simulator-version-min=${IOS_MIN_VERSION}"

    # x86_64-simulator
    build_openssl_variant "iphonesimulator-x86_64" "iossimulator-x86_64-xcrun" "iphonesimulator-x86_64" "-mios-simulator-version-min=${IOS_MIN_VERSION}"

    # macOS arm64
    build_openssl_variant "macos-arm64" "darwin64-arm64-cc" "macos-arm64" "-mmacosx-version-min=${MACOS_MIN_VERSION}"

    # macOS x86_64
    build_openssl_variant "macos-x86_64" "darwin64-x86_64-cc" "macos-x86_64" "-mmacosx-version-min=${MACOS_MIN_VERSION}"

    # Mac Catalyst arm64
    build_openssl_variant "catalyst-arm64" "darwin64-arm64-cc" "catalyst-arm64" "-target arm64-apple-ios${IOS_MIN_VERSION}-macabi"

    # Mac Catalyst x86_64
    build_openssl_variant "catalyst-x86_64" "darwin64-x86_64-cc" "catalyst-x86_64" "-target x86_64-apple-ios${IOS_MIN_VERSION}-macabi"

    # arm64-v8a
    if [ -d "$NDK_PATH" ]; then
        build_openssl_variant "android-arm64-v8a" "android-arm64" "arm64-v8a" "" "-D__ANDROID_API__=${API_LEVEL}"

        # armeabi-v7a
        build_openssl_variant "android-armeabi-v7a" "android-arm" "armeabi-v7a" "" "-D__ANDROID_API__=${API_LEVEL}"

        build_openssl_variant "android-x86" "android-x86" "x86" "" "-D__ANDROID_API__=${API_LEVEL}"

        build_openssl_variant "android-x86_64" "android-x86_64" "x86_64" "" "-D__ANDROID_API__=${API_LEVEL}"
    fi
fi

# Apple Platforms (macOS, iOS, Catalyst)
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "Building for Apple platforms..."
    
    # SDK paths
    MACOS_SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
    IOS_SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
    IOS_SIM_SDK_PATH=$(xcrun --sdk iphonesimulator --show-sdk-path)
    
    # =========================================================================
    # macOS builds
    # =========================================================================
    echo "Building for macOS architectures..."

    # macOS arm64
    build_arch "arm64" "macos" \
        "$(xcrun --sdk macosx --find clang)" \
        "$(xcrun --sdk macosx --find clang++)" \
        "-I${OPENSSL_PREBUILT_FOLDER}/include-macos-arm64 -arch arm64 -mmacosx-version-min=${MACOS_MIN_VERSION} -isysroot ${MACOS_SDK_PATH}" \
        "-L${OPENSSL_PREBUILT_FOLDER}/macos-arm64 -arch arm64 -mmacosx-version-min=${MACOS_MIN_VERSION} -isysroot ${MACOS_SDK_PATH}" \
        "--disable-iconv --disable-zlib --enable-openssl --disable-securetransport"

    fix_dynamic_linkage "${OUTPUT_DIR}/macos/arm64/lib/libavcodec.${AVCODEC_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/macos/arm64/lib/libavformat.${AVFORMAT_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/macos/arm64/lib/libavutil.${AVUTIL_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/macos/arm64/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib"
    rm -rf "${OUTPUT_DIR}/macos/arm64/share"

    # macOS x86_64
    build_arch "x86_64" "macos" \
        "$(xcrun --sdk macosx --find clang)" \
        "$(xcrun --sdk macosx --find clang++)" \
        "-I${OPENSSL_PREBUILT_FOLDER}/include-macos-x86_64 -arch x86_64 -mmacosx-version-min=${MACOS_MIN_VERSION} -isysroot ${MACOS_SDK_PATH}" \
        "-L${OPENSSL_PREBUILT_FOLDER}/macos-x86_64 -arch x86_64 -mmacosx-version-min=${MACOS_MIN_VERSION} -isysroot ${MACOS_SDK_PATH}" \
        "--disable-iconv --disable-zlib --enable-openssl --disable-securetransport"

    fix_dynamic_linkage "${OUTPUT_DIR}/macos/x86_64/lib/libavcodec.${AVCODEC_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/macos/x86_64/lib/libavformat.${AVFORMAT_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/macos/x86_64/lib/libavutil.${AVUTIL_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/macos/x86_64/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib"
    rm -rf "${OUTPUT_DIR}/macos/x86_64/share"

    # Create universal macOS libraries
    mkdir -p "${OUTPUT_DIR}/macos/fat/lib"
    lipo -create \
        "${OUTPUT_DIR}/macos/arm64/lib/libavcodec.${AVCODEC_VERSION}.dylib" \
        "${OUTPUT_DIR}/macos/x86_64/lib/libavcodec.${AVCODEC_VERSION}.dylib" \
        -output "${OUTPUT_DIR}/macos/fat/lib/libavcodec.${AVCODEC_VERSION}.dylib"
    lipo -create \
        "${OUTPUT_DIR}/macos/arm64/lib/libavformat.${AVFORMAT_VERSION}.dylib" \
        "${OUTPUT_DIR}/macos/x86_64/lib/libavformat.${AVFORMAT_VERSION}.dylib" \
        -output "${OUTPUT_DIR}/macos/fat/lib/libavformat.${AVFORMAT_VERSION}.dylib"
    lipo -create \
        "${OUTPUT_DIR}/macos/arm64/lib/libavutil.${AVUTIL_VERSION}.dylib" \
        "${OUTPUT_DIR}/macos/x86_64/lib/libavutil.${AVUTIL_VERSION}.dylib" \
        -output "${OUTPUT_DIR}/macos/fat/lib/libavutil.${AVUTIL_VERSION}.dylib"
    lipo -create \
        "${OUTPUT_DIR}/macos/arm64/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib" \
        "${OUTPUT_DIR}/macos/x86_64/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib" \
        -output "${OUTPUT_DIR}/macos/fat/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib"

    mv "${OUTPUT_DIR}/macos/fat/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib" "${OUTPUT_DIR}/macos/fat/lib/libswresample.dylib"
    mv "${OUTPUT_DIR}/macos/fat/lib/libavutil.${AVUTIL_VERSION}.dylib" "${OUTPUT_DIR}/macos/fat/lib/libavutil.dylib"
    mv "${OUTPUT_DIR}/macos/fat/lib/libavformat.${AVFORMAT_VERSION}.dylib" "${OUTPUT_DIR}/macos/fat/lib/libavformat.dylib"
    mv "${OUTPUT_DIR}/macos/fat/lib/libavcodec.${AVCODEC_VERSION}.dylib" "${OUTPUT_DIR}/macos/fat/lib/libavcodec.dylib"
    cp -R "${OUTPUT_DIR}/macos/arm64/include" "${OUTPUT_DIR}/macos/fat/"

    echo "macOS builds completed!"

    # =========================================================================
    # iOS builds
    # =========================================================================
    echo "Building for iOS architectures..."
    
    # iOS Device architecture
    build_arch "arm64" "darwin" \
        "$(xcrun --sdk iphoneos --find clang)" \
        "$(xcrun --sdk iphoneos --find clang++)" \
        "-I${OPENSSL_PREBUILT_FOLDER}/include-iphoneos -arch arm64 -mios-version-min=${IOS_MIN_VERSION} -isysroot ${IOS_SDK_PATH}" \
        "-L${OPENSSL_PREBUILT_FOLDER}/iphoneos -arch arm64 -mios-version-min=${IOS_MIN_VERSION} -isysroot ${IOS_SDK_PATH}" \
        "--disable-iconv --disable-zlib --enable-openssl --disable-securetransport"

    fix_dynamic_linkage "${OUTPUT_DIR}/ios/iphoneos/lib/libavcodec.${AVCODEC_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/ios/iphoneos/lib/libavformat.${AVFORMAT_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/ios/iphoneos/lib/libavutil.${AVUTIL_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/ios/iphoneos/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib"
    
    rm -rf "${OUTPUT_DIR}/ios/iphoneos/share"

    # iOS Simulator arm (Silicon Macs)
    build_arch "arm64" "darwinsim" \
        "$(xcrun --sdk iphonesimulator --find clang)" \
        "$(xcrun --sdk iphonesimulator --find clang++)" \
        "-I${OPENSSL_PREBUILT_FOLDER}/include-iphonesimulator -arch arm64 -mios-simulator-version-min=${IOS_MIN_VERSION} -isysroot ${IOS_SIM_SDK_PATH}" \
        "-L${OPENSSL_PREBUILT_FOLDER}/iphonesimulator -arch arm64 -mios-simulator-version-min=${IOS_MIN_VERSION} -isysroot ${IOS_SIM_SDK_PATH}" \
        "--disable-iconv --disable-zlib --enable-openssl --disable-securetransport"

    fix_dynamic_linkage "${OUTPUT_DIR}/ios/iphonesimulator_arm64/lib/libavcodec.${AVCODEC_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/ios/iphonesimulator_arm64/lib/libavformat.${AVFORMAT_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/ios/iphonesimulator_arm64/lib/libavutil.${AVUTIL_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/ios/iphonesimulator_arm64/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib"

    rm -rf "${OUTPUT_DIR}/ios/iphonesimulator_arm64/share"

    # iOS Simulator x86_64 (Intel Macs)
    build_arch "x86_64" "darwinsim" \
        "$(xcrun --sdk iphonesimulator --find clang)" \
        "$(xcrun --sdk iphonesimulator --find clang++)" \
        "-I${OPENSSL_PREBUILT_FOLDER}/include-iphonesimulator-x86_64 -arch x86_64 -mios-simulator-version-min=${IOS_MIN_VERSION} -isysroot ${IOS_SIM_SDK_PATH}" \
        "-L${OPENSSL_PREBUILT_FOLDER}/iphonesimulator-x86_64 -arch x86_64 -mios-simulator-version-min=${IOS_MIN_VERSION} -isysroot ${IOS_SIM_SDK_PATH}" \
        "--disable-iconv --disable-zlib --enable-openssl --disable-securetransport"

    fix_dynamic_linkage "${OUTPUT_DIR}/ios/iphonesimulator_x86_64/lib/libavcodec.${AVCODEC_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/ios/iphonesimulator_x86_64/lib/libavformat.${AVFORMAT_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/ios/iphonesimulator_x86_64/lib/libavutil.${AVUTIL_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/ios/iphonesimulator_x86_64/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib"

    rm -rf "${OUTPUT_DIR}/ios/iphonesimulator_x86_64/share"

    mkdir -p "${OUTPUT_DIR}/ios/iphonesimulator/lib"
    # Create universal simulator libraries
    lipo -create \
        "${OUTPUT_DIR}/ios/iphonesimulator_arm64/lib/libavcodec.${AVCODEC_VERSION}.dylib" \
        "${OUTPUT_DIR}/ios/iphonesimulator_x86_64/lib/libavcodec.${AVCODEC_VERSION}.dylib" \
        -output "${OUTPUT_DIR}/ios/iphonesimulator/lib/libavcodec.${AVCODEC_VERSION}.dylib"
    lipo -create \
        "${OUTPUT_DIR}/ios/iphonesimulator_arm64/lib/libavformat.${AVFORMAT_VERSION}.dylib" \
        "${OUTPUT_DIR}/ios/iphonesimulator_x86_64/lib/libavformat.${AVFORMAT_VERSION}.dylib" \
        -output "${OUTPUT_DIR}/ios/iphonesimulator/lib/libavformat.${AVFORMAT_VERSION}.dylib"
    
    lipo -create \
        "${OUTPUT_DIR}/ios/iphonesimulator_arm64/lib/libavutil.${AVUTIL_VERSION}.dylib" \
        "${OUTPUT_DIR}/ios/iphonesimulator_x86_64/lib/libavutil.${AVUTIL_VERSION}.dylib" \
        -output "${OUTPUT_DIR}/ios/iphonesimulator/lib/libavutil.${AVUTIL_VERSION}.dylib" 
       
    lipo -create \
        "${OUTPUT_DIR}/ios/iphonesimulator_arm64/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib" \
        "${OUTPUT_DIR}/ios/iphonesimulator_x86_64/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib" \
        -output "${OUTPUT_DIR}/ios/iphonesimulator/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib"

    mv "${OUTPUT_DIR}/ios/iphonesimulator/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib" "${OUTPUT_DIR}/ios/iphonesimulator/lib/libswresample.dylib"
    mv "${OUTPUT_DIR}/ios/iphonesimulator/lib/libavutil.${AVUTIL_VERSION}.dylib" "${OUTPUT_DIR}/ios/iphonesimulator/lib/libavutil.dylib"
    mv "${OUTPUT_DIR}/ios/iphonesimulator/lib/libavformat.${AVFORMAT_VERSION}.dylib" "${OUTPUT_DIR}/ios/iphonesimulator/lib/libavformat.dylib"
    mv "${OUTPUT_DIR}/ios/iphonesimulator/lib/libavcodec.${AVCODEC_VERSION}.dylib" "${OUTPUT_DIR}/ios/iphonesimulator/lib/libavcodec.dylib"

    echo "iOS builds completed!"

    # =========================================================================
    # Mac Catalyst builds
    # =========================================================================
    echo "Building for Mac Catalyst architectures..."

    # Mac Catalyst arm64
    build_arch "arm64" "catalyst" \
        "$(xcrun --sdk macosx --find clang)" \
        "$(xcrun --sdk macosx --find clang++)" \
        "-I${OPENSSL_PREBUILT_FOLDER}/include-catalyst-arm64 -target arm64-apple-ios${IOS_MIN_VERSION}-macabi -isysroot ${MACOS_SDK_PATH}" \
        "-L${OPENSSL_PREBUILT_FOLDER}/catalyst-arm64 -target arm64-apple-ios${IOS_MIN_VERSION}-macabi -isysroot ${MACOS_SDK_PATH}" \
        "--disable-iconv --disable-zlib --enable-openssl --disable-securetransport"

    fix_dynamic_linkage "${OUTPUT_DIR}/catalyst/arm64/lib/libavcodec.${AVCODEC_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/catalyst/arm64/lib/libavformat.${AVFORMAT_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/catalyst/arm64/lib/libavutil.${AVUTIL_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/catalyst/arm64/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib"
    rm -rf "${OUTPUT_DIR}/catalyst/arm64/share"

    # Mac Catalyst x86_64
    build_arch "x86_64" "catalyst" \
        "$(xcrun --sdk macosx --find clang)" \
        "$(xcrun --sdk macosx --find clang++)" \
        "-I${OPENSSL_PREBUILT_FOLDER}/include-catalyst-x86_64 -target x86_64-apple-ios${IOS_MIN_VERSION}-macabi -isysroot ${MACOS_SDK_PATH}" \
        "-L${OPENSSL_PREBUILT_FOLDER}/catalyst-x86_64 -target x86_64-apple-ios${IOS_MIN_VERSION}-macabi -isysroot ${MACOS_SDK_PATH}" \
        "--disable-iconv --disable-zlib --enable-openssl --disable-securetransport"

    fix_dynamic_linkage "${OUTPUT_DIR}/catalyst/x86_64/lib/libavcodec.${AVCODEC_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/catalyst/x86_64/lib/libavformat.${AVFORMAT_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/catalyst/x86_64/lib/libavutil.${AVUTIL_VERSION}.dylib"
    fix_dynamic_linkage "${OUTPUT_DIR}/catalyst/x86_64/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib"
    rm -rf "${OUTPUT_DIR}/catalyst/x86_64/share"

    # Create universal catalyst libraries
    mkdir -p "${OUTPUT_DIR}/catalyst/fat/lib"
    lipo -create \
        "${OUTPUT_DIR}/catalyst/arm64/lib/libavcodec.${AVCODEC_VERSION}.dylib" \
        "${OUTPUT_DIR}/catalyst/x86_64/lib/libavcodec.${AVCODEC_VERSION}.dylib" \
        -output "${OUTPUT_DIR}/catalyst/fat/lib/libavcodec.${AVCODEC_VERSION}.dylib"
    lipo -create \
        "${OUTPUT_DIR}/catalyst/arm64/lib/libavformat.${AVFORMAT_VERSION}.dylib" \
        "${OUTPUT_DIR}/catalyst/x86_64/lib/libavformat.${AVFORMAT_VERSION}.dylib" \
        -output "${OUTPUT_DIR}/catalyst/fat/lib/libavformat.${AVFORMAT_VERSION}.dylib"
    lipo -create \
        "${OUTPUT_DIR}/catalyst/arm64/lib/libavutil.${AVUTIL_VERSION}.dylib" \
        "${OUTPUT_DIR}/catalyst/x86_64/lib/libavutil.${AVUTIL_VERSION}.dylib" \
        -output "${OUTPUT_DIR}/catalyst/fat/lib/libavutil.${AVUTIL_VERSION}.dylib"
    lipo -create \
        "${OUTPUT_DIR}/catalyst/arm64/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib" \
        "${OUTPUT_DIR}/catalyst/x86_64/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib" \
        -output "${OUTPUT_DIR}/catalyst/fat/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib"

    mv "${OUTPUT_DIR}/catalyst/fat/lib/libswresample.${SWRRESAMPLE_VERSION}.dylib" "${OUTPUT_DIR}/catalyst/fat/lib/libswresample.dylib"
    mv "${OUTPUT_DIR}/catalyst/fat/lib/libavutil.${AVUTIL_VERSION}.dylib" "${OUTPUT_DIR}/catalyst/fat/lib/libavutil.dylib"
    mv "${OUTPUT_DIR}/catalyst/fat/lib/libavformat.${AVFORMAT_VERSION}.dylib" "${OUTPUT_DIR}/catalyst/fat/lib/libavformat.dylib"
    mv "${OUTPUT_DIR}/catalyst/fat/lib/libavcodec.${AVCODEC_VERSION}.dylib" "${OUTPUT_DIR}/catalyst/fat/lib/libavcodec.dylib"
    cp -R "${OUTPUT_DIR}/catalyst/arm64/include" "${OUTPUT_DIR}/catalyst/fat/"

    echo "Mac Catalyst builds completed!"

    sync_openssl_dependency_outputs
    sync_ffmpeg_headers

    # Create iOS XCFrameworks (ios + simulator + catalyst) in outputs/ffmpeg_ios.
    FFMPEG_FRAMEWORK_SOURCE_DIR="${OUTPUT_DIR}" \
    FFMPEG_XCFRAMEWORK_OUTPUT_DIR="${FFMPEG_IOS_OUTPUT_DIR}" \
    bash "$SCRIPT_DIR/create_xcframework.sh"
    
    echo "Apple platform builds completed!"
else
    echo "Skipping Apple platform builds (requires macOS)"
fi

# Android Architectures
if [ -n "$ANDROID_NDK_ROOT" ] || [ -n "$NDK_ROOT" ]; then
    echo "Building for Android architectures..."
        
    # ARM64-v8a
    build_arch "aarch64" "android" \
        "${TOOLCHAIN}/bin/aarch64-linux-android${API_LEVEL}-clang" \
        "${TOOLCHAIN}/bin/aarch64-linux-android${API_LEVEL}-clang++" \
        "-I${OPENSSL_PREBUILT_FOLDER}/include-arm64-v8a -I${TOOLCHAIN}/sysroot/usr/include -fPIC -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        "-L${OPENSSL_PREBUILT_FOLDER}/arm64-v8a -L${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/${API_LEVEL} -fPIC -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        "--enable-openssl --extra-libs=-lz"

    rm -rf ${OUTPUT_DIR}/android/arm64-v8a/share
    
    # ARMv7a
    build_arch "armv7a" "android" \
        "${TOOLCHAIN}/bin/armv7a-linux-androideabi${API_LEVEL}-clang" \
        "${TOOLCHAIN}/bin/armv7a-linux-androideabi${API_LEVEL}-clang++" \
        "-I${OPENSSL_PREBUILT_FOLDER}/include-armeabi-v7a -I${TOOLCHAIN}/sysroot/usr/include -fPIC -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        "-L${OPENSSL_PREBUILT_FOLDER}/armeabi-v7a -L${TOOLCHAIN}/sysroot/usr/lib/arm-linux-android/${API_LEVEL} -fPIC -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        "--enable-openssl --extra-libs=-lz"

    rm -rf ${OUTPUT_DIR}/android/armeabi-v7a/share

    # x86
    build_arch "x86" "android" \
        "${TOOLCHAIN}/bin/i686-linux-android${API_LEVEL}-clang" \
        "${TOOLCHAIN}/bin/i686-linux-android${API_LEVEL}-clang++" \
        "-I${OPENSSL_PREBUILT_FOLDER}/include-x86 -I${TOOLCHAIN}/darwin-x86_64/sysroot/usr/include -fPIC -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        "-L${OPENSSL_PREBUILT_FOLDER}/x86 -L${TOOLCHAIN}/darwin-x86_64/sysroot/usr/lib/i686-linux-android/${API_LEVEL} -fPIC -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        "--enable-openssl --extra-libs=-lz"

    rm -rf ${OUTPUT_DIR}/android/x86/share


    # x86_64
    build_arch "x86_64" "android" \
        "${TOOLCHAIN}/bin/x86_64-linux-android${API_LEVEL}-clang" \
        "${TOOLCHAIN}/bin/x86_64-linux-android${API_LEVEL}-clang++" \
        "-I${OPENSSL_PREBUILT_FOLDER}/include-x86_64 -I${TOOLCHAIN}/darwin-x86_64/sysroot/usr/include -fPIC -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        "-L${OPENSSL_PREBUILT_FOLDER}/x86_64 -L${TOOLCHAIN}/darwin-x86_64/sysroot/usr/lib/x86_64-linux-android/${API_LEVEL} -fPIC -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        "--enable-openssl --extra-libs=-lz"

    rm -rf ${OUTPUT_DIR}/android/x86_64/share

    sync_ffmpeg_android_libs

        
    echo "Android builds completed! Exported libs: ${FFMPEG_ANDROID_OUTPUT_DIR}"
else
    echo "Skipping Android builds (ANDROID_NDK_ROOT or NDK_ROOT not set)"
fi

postprocess_ffmpeg_headers

echo "All FFmpeg builds completed!"
