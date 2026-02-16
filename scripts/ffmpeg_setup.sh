#!/bin/bash

# FFmpeg Mobile Architecture Build Script
# Builds shared ffmpeg binaries for iOS, macOS, Mac Catalyst, and Android architectures
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
SOURCES_DIR="$ROOT_DIR/sources"
SOURCE_DIR="$SOURCES_DIR/ffmpeg"
BUILD_DIR="$ROOT_DIR/build/ffmpeg"
OUTPUT_DIR="$ROOT_DIR/outputs/ffmpeg"

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
    
    SOURCE_PATH="${BUILD_DIR}/ffmpeg-${PLATFORM_NAME}-${ARCH_NAME}"
    OUTPUT_PATH="${OUTPUT_DIR}/${PLATFORM_NAME}/${ARCH_NAME}"
    
    mkdir -p "${OUTPUT_PATH}"
    
    echo "Copying source for ${PLATFORM_NAME} ${ARCH_NAME}..."
    rm -rf "${SOURCE_PATH}"
    cp -r "${SOURCE_DIR}" "${SOURCE_PATH}"
    
    cd "${SOURCE_PATH}"
    
    make distclean 2>/dev/null || true
    
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

OPENSSL_PREBUILT_FOLDER="${ROOT_DIR}/build/openssl-prebuilt"
if [ ! -d "$OPENSSL_PREBUILT_FOLDER" ]; then
    echo "Cloning and building OpenSSL..."
    OPENSSL_BUILD_DIR="$BUILD_DIR/openssl"
    if [ ! -d "$OPENSSL_BUILD_DIR" ]; then
        git clone https://github.com/openssl/openssl.git "$OPENSSL_BUILD_DIR"
    fi
    cd "$OPENSSL_BUILD_DIR"
    mkdir -p "${OPENSSL_PREBUILT_FOLDER}/include"

    # ios-arm
    export CFLAGS="-mios-version-min=${IOS_MIN_VERSION}"
    ./Configure ios64-xcrun no-shared no-asm no-tests
    make build_libs -j10
    mkdir -p ${OPENSSL_PREBUILT_FOLDER}/iphoneos && cp libcrypto.a libssl.a "${OPENSSL_PREBUILT_FOLDER}/iphoneos"
    cp -r include/crypto include/openssl "${OPENSSL_PREBUILT_FOLDER}/include"
    make clean
    unset CFLAGS

    # arm-simulator
    export CFLAGS="-mios-simulator-version-min=${IOS_MIN_VERSION}"
    ./Configure iossimulator-arm64-xcrun no-shared no-asm no-tests
    make build_libs -j10
    mkdir -p ${OPENSSL_PREBUILT_FOLDER}/iphonesimulator && cp libcrypto.a libssl.a "${OPENSSL_PREBUILT_FOLDER}/iphonesimulator"
    make clean
    unset CFLAGS

    # x86_64-simulator
    export CFLAGS="-mios-simulator-version-min=${IOS_MIN_VERSION}"
    ./Configure iossimulator-x86_64-xcrun no-shared no-asm no-tests
    make build_libs -j10
    mkdir -p ${OPENSSL_PREBUILT_FOLDER}/iphonesimulator-x86_64 && cp libcrypto.a libssl.a "${OPENSSL_PREBUILT_FOLDER}/iphonesimulator-x86_64"
    make clean
    unset CFLAGS

    # macOS arm64
    export CFLAGS="-mmacosx-version-min=${MACOS_MIN_VERSION}"
    ./Configure darwin64-arm64-cc no-shared no-asm no-tests
    make build_libs -j10
    mkdir -p ${OPENSSL_PREBUILT_FOLDER}/macos-arm64 && cp libcrypto.a libssl.a "${OPENSSL_PREBUILT_FOLDER}/macos-arm64"
    make clean
    unset CFLAGS

    # macOS x86_64
    export CFLAGS="-mmacosx-version-min=${MACOS_MIN_VERSION}"
    ./Configure darwin64-x86_64-cc no-shared no-asm no-tests
    make build_libs -j10
    mkdir -p ${OPENSSL_PREBUILT_FOLDER}/macos-x86_64 && cp libcrypto.a libssl.a "${OPENSSL_PREBUILT_FOLDER}/macos-x86_64"
    make clean
    unset CFLAGS

    # Mac Catalyst arm64
    export CFLAGS="-target arm64-apple-ios${IOS_MIN_VERSION}-macabi"
    ./Configure darwin64-arm64-cc no-shared no-asm no-tests
    make build_libs -j10
    mkdir -p ${OPENSSL_PREBUILT_FOLDER}/catalyst-arm64 && cp libcrypto.a libssl.a "${OPENSSL_PREBUILT_FOLDER}/catalyst-arm64"
    make clean
    unset CFLAGS

    # Mac Catalyst x86_64
    export CFLAGS="-target x86_64-apple-ios${IOS_MIN_VERSION}-macabi"
    ./Configure darwin64-x86_64-cc no-shared no-asm no-tests
    make build_libs -j10
    mkdir -p ${OPENSSL_PREBUILT_FOLDER}/catalyst-x86_64 && cp libcrypto.a libssl.a "${OPENSSL_PREBUILT_FOLDER}/catalyst-x86_64"
    make clean
    unset CFLAGS

    # arm64-v8a
    if [ -d "$NDK_PATH" ]; then
        ./Configure android-arm64 no-shared no-asm no-tests -D__ANDROID_API__=${API_LEVEL}
        make build_libs -j10
        mkdir -p ${OPENSSL_PREBUILT_FOLDER}/arm64-v8a && cp libcrypto.a libssl.a "${OPENSSL_PREBUILT_FOLDER}/arm64-v8a"
        make clean

        # armeabi-v7a
        ./Configure android-arm no-shared no-asm no-tests -D__ANDROID_API__=${API_LEVEL}
        make build_libs -j10
        mkdir -p ${OPENSSL_PREBUILT_FOLDER}/armeabi-v7a && cp libcrypto.a libssl.a "${OPENSSL_PREBUILT_FOLDER}/armeabi-v7a"
        make clean

        ./Configure android-x86 no-shared no-asm no-tests -D__ANDROID_API__=${API_LEVEL}
        make build_libs -j10
        mkdir -p ${OPENSSL_PREBUILT_FOLDER}/x86 && cp libcrypto.a libssl.a "${OPENSSL_PREBUILT_FOLDER}/x86"
        make clean

        ./Configure android-x86_64 no-shared no-asm no-tests -D__ANDROID_API__=${API_LEVEL}
        make build_libs -j10
        mkdir -p ${OPENSSL_PREBUILT_FOLDER}/x86_64 && cp libcrypto.a libssl.a "${OPENSSL_PREBUILT_FOLDER}/x86_64"
        make clean
    fi

    cd "$ROOT_DIR" && rm -rf "$OPENSSL_BUILD_DIR"
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
        "-I${OPENSSL_PREBUILT_FOLDER}/include -arch arm64 -mmacosx-version-min=${MACOS_MIN_VERSION} -isysroot ${MACOS_SDK_PATH}" \
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
        "-I${OPENSSL_PREBUILT_FOLDER}/include -arch x86_64 -mmacosx-version-min=${MACOS_MIN_VERSION} -isysroot ${MACOS_SDK_PATH}" \
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
        "-I${OPENSSL_PREBUILT_FOLDER}/include -arch arm64 -mios-version-min=${IOS_MIN_VERSION} -isysroot ${IOS_SDK_PATH}" \
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
        "-I${OPENSSL_PREBUILT_FOLDER}/include -arch arm64 -mios-simulator-version-min=${IOS_MIN_VERSION} -isysroot ${IOS_SIM_SDK_PATH}" \
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
        "-I${OPENSSL_PREBUILT_FOLDER}/include -arch x86_64 -mios-simulator-version-min=${IOS_MIN_VERSION} -isysroot ${IOS_SIM_SDK_PATH}" \
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
        "-I${OPENSSL_PREBUILT_FOLDER}/include -target arm64-apple-ios${IOS_MIN_VERSION}-macabi -isysroot ${MACOS_SDK_PATH}" \
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
        "-I${OPENSSL_PREBUILT_FOLDER}/include -target x86_64-apple-ios${IOS_MIN_VERSION}-macabi -isysroot ${MACOS_SDK_PATH}" \
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

    # create frameworks from binaries
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
        "-I${OPENSSL_PREBUILT_FOLDER}/include -I${TOOLCHAIN}/sysroot/usr/include -fPIC -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        "-L${OPENSSL_PREBUILT_FOLDER}/arm64-v8a -L${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/${API_LEVEL} -fPIC -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        "--enable-openssl --extra-libs=-lz"

    rm -rf ${OUTPUT_DIR}/android/arm64-v8a/share
    
    # ARMv7a
    build_arch "armv7a" "android" \
        "${TOOLCHAIN}/bin/armv7a-linux-androideabi${API_LEVEL}-clang" \
        "${TOOLCHAIN}/bin/armv7a-linux-androideabi${API_LEVEL}-clang++" \
        "-I${OPENSSL_PREBUILT_FOLDER}/include -I${TOOLCHAIN}/sysroot/usr/include -fPIC -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        "-L${OPENSSL_PREBUILT_FOLDER}/armeabi-v7a -L${TOOLCHAIN}/sysroot/usr/lib/arm-linux-android/${API_LEVEL} -fPIC -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        "--enable-openssl --extra-libs=-lz"

    rm -rf ${OUTPUT_DIR}/android/armeabi-v7a/share

    # x86
    build_arch "x86" "android" \
        "${TOOLCHAIN}/bin/i686-linux-android${API_LEVEL}-clang" \
        "${TOOLCHAIN}/bin/i686-linux-android${API_LEVEL}-clang++" \
        "-I${OPENSSL_PREBUILT_FOLDER}/include -I${TOOLCHAIN}/darwin-x86_64/sysroot/usr/include -fPIC -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        "-L${OPENSSL_PREBUILT_FOLDER}/x86 -L${TOOLCHAIN}/darwin-x86_64/sysroot/usr/lib/i686-linux-android/${API_LEVEL} -fPIC -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        "--enable-openssl --extra-libs=-lz"

    rm -rf ${OUTPUT_DIR}/android/x86/share


    # x86_64
    build_arch "x86_64" "android" \
        "${TOOLCHAIN}/bin/x86_64-linux-android${API_LEVEL}-clang" \
        "${TOOLCHAIN}/bin/x86_64-linux-android${API_LEVEL}-clang++" \
        "-I${OPENSSL_PREBUILT_FOLDER}/include -I${TOOLCHAIN}/darwin-x86_64/sysroot/usr/include -fPIC -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        "-L${OPENSSL_PREBUILT_FOLDER}/x86_64 -L${TOOLCHAIN}/darwin-x86_64/sysroot/usr/lib/x86_64-linux-android/${API_LEVEL} -fPIC -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
        "--enable-openssl --extra-libs=-lz"

    rm -rf ${OUTPUT_DIR}/android/x86_64/share

        
    echo "Android builds completed!"
else
    echo "Skipping Android builds (ANDROID_NDK_ROOT or NDK_ROOT not set)"
fi

rm -rf "${BUILD_DIR}"

echo "All FFmpeg builds completed!"
