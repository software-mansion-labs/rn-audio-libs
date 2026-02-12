#!/bin/bash
set -euo pipefail

# Build libvorbis (and its dependency libogg) for macOS, iOS (device+sim), and Android (4 ABIs).
#
# Output layout:
#   outputs/vorbis/macos/<arch>/lib/libvorbis.a
#   outputs/vorbis/macos/<arch>/lib/libogg.a
#   outputs/vorbis/ios/<sdk>-<arch>/lib/libvorbis.a
#   outputs/vorbis/ios/<sdk>-<arch>/lib/libogg.a
#   outputs/vorbis/android/<abi>/lib/libvorbis.a
#   outputs/vorbis/android/<abi>/lib/libogg.a
#
# Usage:
#   Run from root directory: yarn build:vorbis

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SOURCES_DIR="$ROOT_DIR/sources"
OGG_DIR="$SOURCES_DIR/ogg"
VORBIS_DIR="$SOURCES_DIR/vorbis"
OUTPUT_DIR="$ROOT_DIR/outputs/vorbis"
BUILD_DIR="$ROOT_DIR/build/vorbis"

JOBS="$(sysctl -n hw.ncpu)"
: "${JOBS:=8}"

IOS_MIN_VERSION="${IOS_MIN_VERSION:-15.1}"
MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-11.0}"
ANDROID_API="${ANDROID_API:-24}"

# Prefer ANDROID_NDK_ROOT, fallback to ANDROID_NDK
ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-${ANDROID_NDK:-}}"

# Detect build machine for cross-compilation (convert arm64 -> aarch64 for old config.sub)
BUILD_ARCH="$(uname -m)"
if [[ "$BUILD_ARCH" == "arm64" ]]; then
    BUILD_ARCH="aarch64"
fi
BUILD_MACHINE="${BUILD_ARCH}-apple-darwin"

# Read versions from configs.json
CONFIG_FILE="$ROOT_DIR/configs.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: configs.json not found at $CONFIG_FILE"
    exit 1
fi

OGG_VERSION=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['ogg']['version'])")
VORBIS_VERSION=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['vorbis']['version'])")

if [ -z "$OGG_VERSION" ]; then
    echo "Error: Could not read ogg version from configs.json"
    exit 1
fi

if [ -z "$VORBIS_VERSION" ]; then
    echo "Error: Could not read vorbis version from configs.json"
    exit 1
fi

# ============================================================================
# DOWNLOAD SOURCES
# ============================================================================

download_ogg() {
    echo "=== Downloading libogg v$OGG_VERSION ==="

    mkdir -p "$SOURCES_DIR"

    OGG_URL="https://downloads.xiph.org/releases/ogg/libogg-${OGG_VERSION}.tar.gz"
    OGG_TARBALL="$SOURCES_DIR/libogg-${OGG_VERSION}.tar.gz"

    if [ -d "$OGG_DIR" ]; then
        echo "Removing existing ogg directory..."
        rm -rf "$OGG_DIR"
    fi

    if [ ! -f "$OGG_TARBALL" ]; then
        echo "Downloading ogg source from $OGG_URL..."
        curl -L -o "$OGG_TARBALL" "$OGG_URL"
    else
        echo "Using cached tarball: $OGG_TARBALL"
    fi

    echo "Extracting ogg source..."
    tar -xzf "$OGG_TARBALL" -C "$SOURCES_DIR"

    mv "$SOURCES_DIR/libogg-${OGG_VERSION}" "$OGG_DIR"

    echo "=== libogg v$OGG_VERSION downloaded to $OGG_DIR ==="
}

download_vorbis() {
    echo "=== Downloading libvorbis v$VORBIS_VERSION ==="

    mkdir -p "$SOURCES_DIR"

    VORBIS_URL="https://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VERSION}.tar.gz"
    VORBIS_TARBALL="$SOURCES_DIR/libvorbis-${VORBIS_VERSION}.tar.gz"

    if [ -d "$VORBIS_DIR" ]; then
        echo "Removing existing vorbis directory..."
        rm -rf "$VORBIS_DIR"
    fi

    if [ ! -f "$VORBIS_TARBALL" ]; then
        echo "Downloading vorbis source from $VORBIS_URL..."
        curl -L -o "$VORBIS_TARBALL" "$VORBIS_URL"
    else
        echo "Using cached tarball: $VORBIS_TARBALL"
    fi

    echo "Extracting vorbis source..."
    tar -xzf "$VORBIS_TARBALL" -C "$SOURCES_DIR"

    mv "$SOURCES_DIR/libvorbis-${VORBIS_VERSION}" "$VORBIS_DIR"

    echo "=== libvorbis v$VORBIS_VERSION downloaded to $VORBIS_DIR ==="
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
    local source_dir="$1"
    if [[ -f "$source_dir/config.status" || -f "$source_dir/Makefile" || -f "$source_dir/config.h" ]]; then
        echo "Source tree appears configured in-tree; cleaning with make distclean..."
        (cd "$source_dir" && make distclean) || true
        rm -f "$source_dir/config.status" "$source_dir/config.h" "$source_dir/Makefile"
        rm -rf "$source_dir/autom4te.cache"
    fi
}

patch_source_tree_libtool() {
    local source_dir="$1"
    echo "Patching source tree to remove incompatible flags..."
    # Patch configure, ltmain.sh and any libtool files in source tree
    for file in "$source_dir/configure" "$source_dir/ltmain.sh"; do
        if [[ -f "$file" ]]; then
            # Remove -force_cpusubtype_ALL (deprecated Apple linker flag)
            sed -i '' 's/-force_cpusubtype_ALL//g' "$file"
            # Remove -mno-ieee-fp (GCC-specific x86 flag not supported by clang)
            sed -i '' 's/-mno-ieee-fp//g' "$file"
        fi
    done
    find "$source_dir" -name 'libtool' -type f -exec sed -i '' 's/-force_cpusubtype_ALL//g' {} \; 2>/dev/null || true
}

run_configure_make_install() {
    local source_dir="$1"
    local build_dir="$2"
    local prefix_dir="$3"
    shift 3

    local -a extra_args=()
    if (($#)); then
        extra_args=("$@")
    fi

    mkdir -p "$build_dir"
    rm -rf "$build_dir"/*
    pushd "$build_dir" >/dev/null

    echo "Running configure in $build_dir"
    # lt_cv_apple_cc_single_mod=yes prevents libtool from using deprecated -force_cpusubtype_ALL flag
    "$source_dir/configure" \
        --prefix="$prefix_dir" \
        --disable-shared \
        --enable-static \
        --disable-doc \
        lt_cv_apple_cc_single_mod=yes \
        ${extra_args[@]:+"${extra_args[@]}"}

    # Fix libtool files to remove deprecated -force_cpusubtype_ALL flag (not supported by modern Apple linkers)
    # Patch in both build dir and source dir (in-tree builds may use source dir's libtool)
    find "$build_dir" -name 'libtool' -type f -exec sed -i '' 's/-force_cpusubtype_ALL//g' {} \; 2>/dev/null || true
    find "$source_dir" -name 'libtool' -type f -exec sed -i '' 's/-force_cpusubtype_ALL//g' {} \; 2>/dev/null || true

    make -j"$JOBS"
    make install

    popd >/dev/null
}

copy_to_output() {
    local platform="$1"
    local arch="$2"
    local ogg_prefix="$3"
    local vorbis_prefix="$4"

    local dest="$OUTPUT_DIR/$platform/$arch"
    mkdir -p "$dest/lib" "$dest/include"

    # Copy ogg
    cp "$ogg_prefix/lib/libogg.a" "$dest/lib/"
    cp -R "$ogg_prefix/include/ogg" "$dest/include/"

    # Copy vorbis (libvorbis, libvorbisfile, libvorbisenc)
    cp "$vorbis_prefix/lib/libvorbis.a" "$dest/lib/"
    cp "$vorbis_prefix/lib/libvorbisfile.a" "$dest/lib/"
    cp "$vorbis_prefix/lib/libvorbisenc.a" "$dest/lib/"
    cp -R "$vorbis_prefix/include/vorbis" "$dest/include/"
}

create_fat_binary() {
    local platform="$1"
    shift
    local -a archs=("$@")

    local dest="$OUTPUT_DIR/$platform/fat"
    mkdir -p "$dest/lib"

    for lib in libogg.a libvorbis.a libvorbisfile.a libvorbisenc.a; do
        local lib_paths=()
        for arch in "${archs[@]}"; do
            lib_paths+=("$OUTPUT_DIR/$platform/$arch/lib/$lib")
        done
        lipo -create "${lib_paths[@]}" -output "$dest/lib/$lib"
    done

    # Copy headers from first arch
    cp -R "$OUTPUT_DIR/$platform/${archs[0]}/include" "$dest/"
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

    local ogg_build_dir="$BUILD_DIR/macos/$arch/ogg"
    local ogg_prefix="$ogg_build_dir/install"

    local vorbis_build_dir="$BUILD_DIR/macos/$arch/vorbis"
    local vorbis_prefix="$vorbis_build_dir/install"

    # Build ogg first
    echo "Building libogg for macOS $arch..."
    run_configure_make_install "$OGG_DIR" "$ogg_build_dir" "$ogg_prefix"

    # Build vorbis with ogg dependency
    echo "Building libvorbis for macOS $arch..."
    export PKG_CONFIG_PATH="$ogg_prefix/lib/pkgconfig"
    export CPPFLAGS="-I$ogg_prefix/include"
    export LDFLAGS="$LDFLAGS -L$ogg_prefix/lib"

    run_configure_make_install "$VORBIS_DIR" "$vorbis_build_dir" "$vorbis_prefix" \
        --with-ogg="$ogg_prefix" \
        --disable-examples \
        --disable-oggtest

    copy_to_output "macos" "$arch" "$ogg_prefix" "$vorbis_prefix"
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

    local ogg_build_dir="$BUILD_DIR/ios/${sdk}-${arch}/ogg"
    local ogg_prefix="$ogg_build_dir/install"

    local vorbis_build_dir="$BUILD_DIR/ios/${sdk}-${arch}/vorbis"
    local vorbis_prefix="$vorbis_build_dir/install"

    # Build ogg first
    echo "Building libogg for iOS $sdk $arch..."
    run_configure_make_install "$OGG_DIR" "$ogg_build_dir" "$ogg_prefix" \
        --build="$BUILD_MACHINE" --host="$host" cross_compiling=yes

    # Build vorbis with ogg dependency
    echo "Building libvorbis for iOS $sdk $arch..."
    export PKG_CONFIG_PATH="$ogg_prefix/lib/pkgconfig"
    export CPPFLAGS="-I$ogg_prefix/include"
    export LDFLAGS="$LDFLAGS -L$ogg_prefix/lib"

    run_configure_make_install "$VORBIS_DIR" "$vorbis_build_dir" "$vorbis_prefix" \
        --build="$BUILD_MACHINE" --host="$host" cross_compiling=yes \
        --with-ogg="$ogg_prefix" \
        --disable-examples \
        --disable-oggtest

    copy_to_output "ios" "${sdk}-${arch}" "$ogg_prefix" "$vorbis_prefix"
}

build_catalyst() {
    local arch="$1"
    local host="$2"

    echo "==> Mac Catalyst: $arch"

    reset_env

    local sdkroot
    sdkroot="$(xcrun --sdk macosx --show-sdk-path)"

    export CC="$(xcrun --sdk macosx --find clang)"
    export AR="$(xcrun --sdk macosx --find ar)"
    export RANLIB="$(xcrun --sdk macosx --find ranlib)"

    local target="${arch}-apple-ios${IOS_MIN_VERSION}-macabi"
    export CFLAGS="-O3 -fPIC -target $target -isysroot $sdkroot"
    export LDFLAGS="-target $target -isysroot $sdkroot"

    local ogg_build_dir="$BUILD_DIR/catalyst/$arch/ogg"
    local ogg_prefix="$ogg_build_dir/install"

    local vorbis_build_dir="$BUILD_DIR/catalyst/$arch/vorbis"
    local vorbis_prefix="$vorbis_build_dir/install"

    # Build ogg first
    echo "Building libogg for Mac Catalyst $arch..."
    run_configure_make_install "$OGG_DIR" "$ogg_build_dir" "$ogg_prefix" \
        --build="$BUILD_MACHINE" --host="$host" cross_compiling=yes

    # Build vorbis with ogg dependency
    echo "Building libvorbis for Mac Catalyst $arch..."
    export PKG_CONFIG_PATH="$ogg_prefix/lib/pkgconfig"
    export CPPFLAGS="-I$ogg_prefix/include"
    export LDFLAGS="$LDFLAGS -L$ogg_prefix/lib"

    run_configure_make_install "$VORBIS_DIR" "$vorbis_build_dir" "$vorbis_prefix" \
        --build="$BUILD_MACHINE" --host="$host" cross_compiling=yes \
        --with-ogg="$ogg_prefix" \
        --disable-examples \
        --disable-oggtest

    copy_to_output "catalyst" "$arch" "$ogg_prefix" "$vorbis_prefix"
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

    local ogg_build_dir="$BUILD_DIR/android/$abi/ogg"
    local ogg_prefix="$ogg_build_dir/install"

    local vorbis_build_dir="$BUILD_DIR/android/$abi/vorbis"
    local vorbis_prefix="$vorbis_build_dir/install"

    # Build ogg first
    echo "Building libogg for Android $abi..."
    run_configure_make_install "$OGG_DIR" "$ogg_build_dir" "$ogg_prefix" \
        --build="$BUILD_MACHINE" --host="$host" cross_compiling=yes

    # Build vorbis with ogg dependency
    echo "Building libvorbis for Android $abi..."
    export PKG_CONFIG_PATH="$ogg_prefix/lib/pkgconfig"
    export CPPFLAGS="-I$ogg_prefix/include"
    export LDFLAGS="-L$ogg_prefix/lib"

    run_configure_make_install "$VORBIS_DIR" "$vorbis_build_dir" "$vorbis_prefix" \
        --build="$BUILD_MACHINE" --host="$host" cross_compiling=yes \
        --with-ogg="$ogg_prefix" \
        --disable-examples \
        --disable-oggtest

    copy_to_output "android" "$abi" "$ogg_prefix" "$vorbis_prefix"
}

# ============================================================================
# MAIN
# ============================================================================

echo "============================================"
echo "Building libvorbis v$VORBIS_VERSION (with libogg v$OGG_VERSION)"
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

# Download sources
download_ogg
download_vorbis

# Clean source trees if needed
clean_source_tree "$OGG_DIR"
clean_source_tree "$VORBIS_DIR"

# Patch source trees to fix libtool issues with modern Apple linkers
patch_source_tree_libtool "$OGG_DIR"
patch_source_tree_libtool "$VORBIS_DIR"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Build macOS (arm64 and x86_64)
build_macos_arch arm64
build_macos_arch x86_64
create_fat_binary "macos" "arm64" "x86_64"

# Build iOS (device and simulator)
build_ios iphoneos arm64 aarch64-apple-darwin
build_ios iphonesimulator arm64 aarch64-apple-darwin
build_ios iphonesimulator x86_64 x86_64-apple-darwin

# Build Mac Catalyst (arm64 and x86_64)
build_catalyst arm64 aarch64-apple-darwin
build_catalyst x86_64 x86_64-apple-darwin
create_fat_binary "catalyst" "arm64" "x86_64"

# Build Android (4 ABIs)
build_android_abi arm64-v8a   aarch64-linux-android      "aarch64-linux-android${ANDROID_API}"
build_android_abi armeabi-v7a armv7a-linux-androideabi   "armv7a-linux-androideabi${ANDROID_API}"
build_android_abi x86_64      x86_64-linux-android       "x86_64-linux-android${ANDROID_API}"
build_android_abi x86         i686-linux-android         "i686-linux-android${ANDROID_API}"

echo
echo "============================================"
echo "Done building libvorbis v$VORBIS_VERSION (with libogg v$OGG_VERSION)"
echo "============================================"
echo "Artifacts are in: $OUTPUT_DIR"
echo "  macOS:    $OUTPUT_DIR/macos/{arm64,x86_64,fat}/lib/{libogg,libvorbis,libvorbisfile,libvorbisenc}.a"
echo "  iOS:      $OUTPUT_DIR/ios/{iphoneos-arm64,iphonesimulator-arm64,iphonesimulator-x86_64}/lib/{libogg,libvorbis,libvorbisfile,libvorbisenc}.a"
echo "  Catalyst: $OUTPUT_DIR/catalyst/{arm64,x86_64,fat}/lib/{libogg,libvorbis,libvorbisfile,libvorbisenc}.a"
echo "  Android:  $OUTPUT_DIR/android/{arm64-v8a,armeabi-v7a,x86_64,x86}/lib/{libogg,libvorbis,libvorbisfile,libvorbisenc}.a"
echo "============================================"
