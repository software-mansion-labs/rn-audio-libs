#!/bin/bash
set -euo pipefail

# Build libopus for macOS, iOS (device+sim), and Android (4 ABIs).
#
# Output layout:
#   outputs/opus/macos/<arch>/lib/libopus.a
#   outputs/opus/ios/<sdk>-<arch>/lib/libopus.a
#   outputs/opus/android/<abi>/lib/libopus.a
#
# Usage:
#   Run from root directory: yarn build:opus

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SOURCES_DIR="$ROOT_DIR/sources"
OPUS_DIR="$SOURCES_DIR/opus"
OUTPUT_DIR="$ROOT_DIR/outputs/opus"
BUILD_DIR="$OPUS_DIR/build"

JOBS="$(sysctl -n hw.ncpu)"
: "${JOBS:=8}"

IOS_MIN_VERSION="${IOS_MIN_VERSION:-15.1}"
MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-11.0}"
ANDROID_API="${ANDROID_API:-24}"

# Prefer ANDROID_NDK_ROOT, fallback to ANDROID_NDK
ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-${ANDROID_NDK:-}}"

# Detect build machine for cross-compilation
BUILD_MACHINE="$(uname -m)-apple-darwin"

# Read opus version from configs.json
CONFIG_FILE="$ROOT_DIR/configs.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: configs.json not found at $CONFIG_FILE"
    exit 1
fi

OPUS_VERSION=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['opus']['version'])")

if [ -z "$OPUS_VERSION" ]; then
    echo "Error: Could not read opus version from configs.json"
    exit 1
fi

# ============================================================================
# DOWNLOAD OPUS SOURCE
# ============================================================================

download_opus() {
    echo "=== Downloading libopus v$OPUS_VERSION ==="

    mkdir -p "$SOURCES_DIR"

    OPUS_URL="https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz"
    OPUS_TARBALL="$SOURCES_DIR/opus-${OPUS_VERSION}.tar.gz"

    if [ -d "$OPUS_DIR" ]; then
        echo "Removing existing opus directory..."
        rm -rf "$OPUS_DIR"
    fi

    if [ ! -f "$OPUS_TARBALL" ]; then
        echo "Downloading opus source from $OPUS_URL..."
        curl -L -o "$OPUS_TARBALL" "$OPUS_URL"
    else
        echo "Using cached tarball: $OPUS_TARBALL"
    fi

    echo "Extracting opus source..."
    tar -xzf "$OPUS_TARBALL" -C "$SOURCES_DIR"

    mv "$SOURCES_DIR/opus-${OPUS_VERSION}" "$OPUS_DIR"

    echo "=== libopus v$OPUS_VERSION downloaded to $OPUS_DIR ==="
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required tool: $1" >&2
        exit 1
    }
}

reset_env() {
    unset CC CXX AR RANLIB STRIP CFLAGS CPPFLAGS LDFLAGS PKG_CONFIG_PATH || true
}

clean_source_tree() {
    if [[ -f "$OPUS_DIR/config.status" || -f "$OPUS_DIR/Makefile" || -f "$OPUS_DIR/config.h" ]]; then
        echo "Source tree appears configured in-tree; cleaning with make distclean..."
        (cd "$OPUS_DIR" && make distclean) || true
        rm -f "$OPUS_DIR/config.status" "$OPUS_DIR/config.h" "$OPUS_DIR/Makefile"
        rm -rf "$OPUS_DIR/autom4te.cache"
    fi
}

run_configure_make_install() {
    local build_dir="$1"
    local prefix_dir="$2"
    shift 2

    local -a extra_args=()
    if (($#)); then
        extra_args=("$@")
    fi

    mkdir -p "$build_dir"
    rm -rf "$build_dir"/*
    pushd "$build_dir" >/dev/null

    echo "Running configure in $build_dir"
    "$OPUS_DIR/configure" \
        --prefix="$prefix_dir" \
        --disable-shared \
        --enable-static \
        --disable-doc \
        --disable-extra-programs \
        ${extra_args[@]:+"${extra_args[@]}"}

    make -j"$JOBS"
    make install

    popd >/dev/null
}

copy_to_output() {
    local platform="$1"
    local arch="$2"
    local prefix="$3"

    local dest="$OUTPUT_DIR/$platform/$arch"
    mkdir -p "$dest/lib" "$dest/include"

    cp "$prefix/lib/libopus.a" "$dest/lib/"
    cp -R "$prefix/include/opus" "$dest/include/"
}

# ============================================================================
# BUILD FUNCTIONS
# ============================================================================

build_macos_arch() {
    local arch="$1"
    echo "==> macOS: $arch"

    reset_env

    local sdkroot
    sdkroot="$(xcrun --sdk macosx --show-sdk-path)"

    export CC="$(xcrun --sdk macosx --find clang)"
    export AR="$(xcrun --sdk macosx --find ar)"
    export RANLIB="$(xcrun --sdk macosx --find ranlib)"

    export CFLAGS="-O3 -fPIC -arch $arch -isysroot $sdkroot -mmacosx-version-min=$MACOS_MIN_VERSION"
    export LDFLAGS="-arch $arch -isysroot $sdkroot -mmacosx-version-min=$MACOS_MIN_VERSION"

    local build_dir="$BUILD_DIR/macos/$arch"
    local prefix="$build_dir/install"

    run_configure_make_install "$build_dir" "$prefix" --disable-asm
    copy_to_output "macos" "$arch" "$prefix"
}

build_ios() {
    local sdk="$1"
    local arch="$2"
    local host="$3"

    echo "==> iOS: $sdk $arch"

    reset_env

    local sdkroot
    sdkroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

    export CC="$(xcrun --sdk "$sdk" --find clang)"
    export AR="$(xcrun --sdk "$sdk" --find ar)"
    export RANLIB="$(xcrun --sdk "$sdk" --find ranlib)"

    export CFLAGS="-O3 -fPIC -arch $arch -isysroot $sdkroot -miphoneos-version-min=$IOS_MIN_VERSION"
    export LDFLAGS="-arch $arch -isysroot $sdkroot -miphoneos-version-min=$IOS_MIN_VERSION"

    local build_dir="$BUILD_DIR/ios/${sdk}-${arch}"
    local prefix="$build_dir/install"

    run_configure_make_install "$build_dir" "$prefix" --build="$BUILD_MACHINE" --host="$host" --disable-asm cross_compiling=yes

    copy_to_output "ios" "${sdk}-${arch}" "$prefix"
}

build_android_abi() {
    local abi="$1"
    local host="$2"
    local target="$3"

    echo "==> Android: $abi (API $ANDROID_API)"

    if [[ -z "$ANDROID_NDK_ROOT" ]]; then
        echo "ERROR: ANDROID_NDK_ROOT (or ANDROID_NDK) is not set." >&2
        exit 1
    fi

    reset_env

    local toolchain="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64"
    if [[ ! -d "$toolchain" ]]; then
        echo "ERROR: NDK toolchain not found at: $toolchain" >&2
        echo "Check ANDROID_NDK_ROOT and that your NDK is installed." >&2
        exit 1
    fi

    export CC="$toolchain/bin/${target}-clang"
    export AR="$toolchain/bin/llvm-ar"
    export RANLIB="$toolchain/bin/llvm-ranlib"
    export STRIP="$toolchain/bin/llvm-strip"

    export CFLAGS="-O3 -fPIC"
    export LDFLAGS=""

    local build_dir="$BUILD_DIR/android/$abi"
    local prefix="$build_dir/install"

    # Explicitly tell configure we're cross-compiling (can't run target binaries)
    run_configure_make_install "$build_dir" "$prefix" --build="$BUILD_MACHINE" --host="$host" cross_compiling=yes

    copy_to_output "android" "$abi" "$prefix"
}

# ============================================================================
# MAIN
# ============================================================================

echo "============================================"
echo "Building libopus v$OPUS_VERSION"
echo "============================================"
echo "Root directory:     $ROOT_DIR"
echo "Sources directory:  $SOURCES_DIR"
echo "Output directory:   $OUTPUT_DIR"
echo "Jobs:               $JOBS"
echo "iOS min:            $IOS_MIN_VERSION"
echo "macOS min:          $MACOS_MIN_VERSION"
echo "Android API:        $ANDROID_API"
echo "============================================"
echo

# Sanity checks
need make
need xcrun
need clang
need ar
need ranlib

# Download opus source
download_opus

# Clean source tree if needed
clean_source_tree

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Build macOS (arm64 and x86_64)
build_macos_arch arm64
build_macos_arch x86_64

# Build iOS (device and simulator)
build_ios iphoneos arm64 arm-apple-darwin
build_ios iphonesimulator arm64 arm-apple-darwin
build_ios iphonesimulator x86_64 x86_64-apple-darwin

# Build Android (4 ABIs)
build_android_abi arm64-v8a   aarch64-linux-android      "aarch64-linux-android${ANDROID_API}"
build_android_abi armeabi-v7a armv7a-linux-androideabi   "armv7a-linux-androideabi${ANDROID_API}"
build_android_abi x86_64      x86_64-linux-android       "x86_64-linux-android${ANDROID_API}"
build_android_abi x86         i686-linux-android         "i686-linux-android${ANDROID_API}"

echo
echo "============================================"
echo "Done building libopus v$OPUS_VERSION"
echo "============================================"
echo "Artifacts are in: $OUTPUT_DIR"
echo "  macOS:   $OUTPUT_DIR/macos/{arm64,x86_64}/lib/libopus.a"
echo "  iOS:     $OUTPUT_DIR/ios/{iphoneos-arm64,iphonesimulator-arm64,iphonesimulator-x86_64}/lib/libopus.a"
echo "  Android: $OUTPUT_DIR/android/{arm64-v8a,armeabi-v7a,x86_64,x86}/lib/libopus.a"
echo "============================================"

