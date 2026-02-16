#!/bin/bash
set -euo pipefail

# Build libopus, libogg, and libopusfile for macOS, iOS (device+sim), and Android (4 ABIs).
#
# Output layout:
#   outputs/include/{ogg,opus,opusfile}
#   outputs/android/<abi>/{libogg,libopus,libopusfile}.a
#   outputs/iphoneos/{libogg,libopus,libopusfile}.a
#   outputs/iphonesimulator/{libogg,libopus,libopusfile}.a
#   outputs/macosx/{libogg,libopus,libopusfile}.a
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
OGG_DIR="$SOURCES_DIR/ogg"
OPUSFILE_DIR="$SOURCES_DIR/opusfile"
OUTPUT_DIR="$ROOT_DIR/outputs"
INCLUDE_OUTPUT_DIR="$OUTPUT_DIR/include"
BUILD_DIR="$ROOT_DIR/build/intermediate/opus"
ARCH_LIBS_DIR="$BUILD_DIR/arch-libs"

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

OPUS_VERSION=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['opus']['version'])")
OGG_VERSION=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['ogg']['version'])")
OPUSFILE_VERSION=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['opusfile']['version'])")

if [ -z "$OPUS_VERSION" ]; then
    echo "Error: Could not read opus version from configs.json"
    exit 1
fi

if [ -z "$OGG_VERSION" ]; then
    echo "Error: Could not read ogg version from configs.json"
    exit 1
fi

if [ -z "$OPUSFILE_VERSION" ]; then
    echo "Error: Could not read opusfile version from configs.json"
    exit 1
fi

# ============================================================================
# DOWNLOAD SOURCES
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

download_opusfile() {
    echo "=== Downloading libopusfile v$OPUSFILE_VERSION ==="

    mkdir -p "$SOURCES_DIR"

    OPUSFILE_URL="https://downloads.xiph.org/releases/opus/opusfile-${OPUSFILE_VERSION}.tar.gz"
    OPUSFILE_TARBALL="$SOURCES_DIR/opusfile-${OPUSFILE_VERSION}.tar.gz"

    if [ -d "$OPUSFILE_DIR" ]; then
        echo "Removing existing opusfile directory..."
        rm -rf "$OPUSFILE_DIR"
    fi

    if [ ! -f "$OPUSFILE_TARBALL" ]; then
        echo "Downloading opusfile source from $OPUSFILE_URL..."
        curl -L -o "$OPUSFILE_TARBALL" "$OPUSFILE_URL"
    else
        echo "Using cached tarball: $OPUSFILE_TARBALL"
    fi

    echo "Extracting opusfile source..."
    tar -xzf "$OPUSFILE_TARBALL" -C "$SOURCES_DIR"

    mv "$SOURCES_DIR/opusfile-${OPUSFILE_VERSION}" "$OPUSFILE_DIR"

    echo "=== libopusfile v$OPUSFILE_VERSION downloaded to $OPUSFILE_DIR ==="
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

patch_source_tree() {
    local source_dir="$1"
    echo "Patching source tree to remove incompatible flags..."
    for file in "$source_dir/configure" "$source_dir/ltmain.sh"; do
        if [[ -f "$file" ]]; then
            # Remove -force_cpusubtype_ALL (deprecated Apple linker flag)
            sed -i '' 's/-force_cpusubtype_ALL//g' "$file"
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

    local run_build_dir="${build_dir}/run-$(date +%s)-$$-$RANDOM"
    mkdir -p "$run_build_dir"
    pushd "$run_build_dir" >/dev/null

    echo "Running configure in $run_build_dir"
    "$source_dir/configure" \
        --prefix="$prefix_dir" \
        --disable-shared \
        --enable-static \
        --disable-doc \
        lt_cv_apple_cc_single_mod=yes \
        ${extra_args[@]:+"${extra_args[@]}"}

    # Fix libtool files to remove deprecated flags
    find "$build_dir" -name 'libtool' -type f -exec sed -i '' 's/-force_cpusubtype_ALL//g' {} \; 2>/dev/null || true

    make -j"$JOBS"
    make install

    popd >/dev/null
}

copy_to_output() {
    local platform="$1"
    local arch="$2"
    local ogg_prefix="$3"
    local opus_prefix="$4"
    local opusfile_prefix="$5"

    local dest
    if [[ "$platform" == "android" ]]; then
        dest="$OUTPUT_DIR/$platform/$arch"
    else
        dest="$ARCH_LIBS_DIR/$platform/$arch"
    fi
    mkdir -p "$dest"

    # Copy ogg
    if [ ! -f "$dest/libogg.a" ]; then
        cp "$ogg_prefix/lib/libogg.a" "$dest/"
    fi

    # Copy opus
    cp "$opus_prefix/lib/libopus.a" "$dest/"

    # Copy opusfile
    cp "$opusfile_prefix/lib/libopusfile.a" "$dest/"

    # Copy merged public headers for all platforms/libraries.
    mkdir -p "$INCLUDE_OUTPUT_DIR/ogg" "$INCLUDE_OUTPUT_DIR/opus" "$INCLUDE_OUTPUT_DIR/opusfile"
    cp -R "$ogg_prefix/include/ogg/." "$INCLUDE_OUTPUT_DIR/ogg/"
    cp -R "$opus_prefix/include/opus/." "$INCLUDE_OUTPUT_DIR/opus/"
    cp "$opusfile_prefix/include/opus/opusfile.h" "$INCLUDE_OUTPUT_DIR/opusfile/"
}

create_fat_binary() {
    local platform="$1"
    shift
    local -a archs=("$@")

    local dest="$OUTPUT_DIR/$platform"
    mkdir -p "$dest"

    for lib in libogg.a libopus.a libopusfile.a; do
        if [ "$lib" = "libogg.a" ] && [ -f "$dest/$lib" ]; then
            continue
        fi
        local lib_paths=()
        for arch in "${archs[@]}"; do
            lib_paths+=("$ARCH_LIBS_DIR/$platform/$arch/$lib")
        done
        if [ "${#lib_paths[@]}" -eq 1 ]; then
            cp "${lib_paths[0]}" "$dest/$lib"
        else
            lipo -create "${lib_paths[@]}" -output "$dest/$lib"
        fi
    done
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

    local opus_build_dir="$BUILD_DIR/macos/$arch/opus"
    local opus_prefix="$opus_build_dir/install"

    local opusfile_build_dir="$BUILD_DIR/macos/$arch/opusfile"
    local opusfile_prefix="$opusfile_build_dir/install"

    # Build ogg first
    echo "Building libogg for macOS $arch..."
    run_configure_make_install "$OGG_DIR" "$ogg_build_dir" "$ogg_prefix"

    # Build opus
    echo "Building libopus for macOS $arch..."
    run_configure_make_install "$OPUS_DIR" "$opus_build_dir" "$opus_prefix" \
        --disable-extra-programs --disable-asm

    # Build opusfile with ogg and opus dependencies
    echo "Building libopusfile for macOS $arch..."
    export PKG_CONFIG_PATH="$ogg_prefix/lib/pkgconfig:$opus_prefix/lib/pkgconfig"
    export CPPFLAGS="-I$ogg_prefix/include -I$opus_prefix/include -I$opus_prefix/include/opus"
    export LDFLAGS="$LDFLAGS -L$ogg_prefix/lib -L$opus_prefix/lib"
    export DEPS_CFLAGS="-I$ogg_prefix/include -I$opus_prefix/include -I$opus_prefix/include/opus"
    export DEPS_LIBS="-L$ogg_prefix/lib -L$opus_prefix/lib -lopus -logg"

    run_configure_make_install "$OPUSFILE_DIR" "$opusfile_build_dir" "$opusfile_prefix" \
        --disable-http --disable-examples

    copy_to_output "macosx" "$arch" "$ogg_prefix" "$opus_prefix" "$opusfile_prefix"
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

    local opus_build_dir="$BUILD_DIR/ios/${sdk}-${arch}/opus"
    local opus_prefix="$opus_build_dir/install"

    local opusfile_build_dir="$BUILD_DIR/ios/${sdk}-${arch}/opusfile"
    local opusfile_prefix="$opusfile_build_dir/install"

    # Build ogg first
    echo "Building libogg for iOS $sdk $arch..."
    run_configure_make_install "$OGG_DIR" "$ogg_build_dir" "$ogg_prefix" \
        --build="$BUILD_MACHINE" --host="$host" cross_compiling=yes

    # Build opus
    echo "Building libopus for iOS $sdk $arch..."
    run_configure_make_install "$OPUS_DIR" "$opus_build_dir" "$opus_prefix" \
        --build="$BUILD_MACHINE" --host="$host" --disable-asm --disable-extra-programs cross_compiling=yes

    # Build opusfile with ogg and opus dependencies
    echo "Building libopusfile for iOS $sdk $arch..."
    export PKG_CONFIG_PATH="$ogg_prefix/lib/pkgconfig:$opus_prefix/lib/pkgconfig"
    export CPPFLAGS="-I$ogg_prefix/include -I$opus_prefix/include -I$opus_prefix/include/opus"
    export LDFLAGS="$LDFLAGS -L$ogg_prefix/lib -L$opus_prefix/lib"
    export DEPS_CFLAGS="-I$ogg_prefix/include -I$opus_prefix/include -I$opus_prefix/include/opus"
    export DEPS_LIBS="-L$ogg_prefix/lib -L$opus_prefix/lib -lopus -logg"

    run_configure_make_install "$OPUSFILE_DIR" "$opusfile_build_dir" "$opusfile_prefix" \
        --build="$BUILD_MACHINE" --host="$host" cross_compiling=yes \
        --disable-http --disable-examples

    copy_to_output "$sdk" "$arch" "$ogg_prefix" "$opus_prefix" "$opusfile_prefix"
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

    local opus_build_dir="$BUILD_DIR/catalyst/$arch/opus"
    local opus_prefix="$opus_build_dir/install"

    local opusfile_build_dir="$BUILD_DIR/catalyst/$arch/opusfile"
    local opusfile_prefix="$opusfile_build_dir/install"

    # Build ogg first
    echo "Building libogg for Mac Catalyst $arch..."
    run_configure_make_install "$OGG_DIR" "$ogg_build_dir" "$ogg_prefix" \
        --build="$BUILD_MACHINE" --host="$host" cross_compiling=yes

    # Build opus
    echo "Building libopus for Mac Catalyst $arch..."
    run_configure_make_install "$OPUS_DIR" "$opus_build_dir" "$opus_prefix" \
        --build="$BUILD_MACHINE" --host="$host" --disable-asm --disable-extra-programs cross_compiling=yes

    # Build opusfile with ogg and opus dependencies
    echo "Building libopusfile for Mac Catalyst $arch..."
    export PKG_CONFIG_PATH="$ogg_prefix/lib/pkgconfig:$opus_prefix/lib/pkgconfig"
    export CPPFLAGS="-I$ogg_prefix/include -I$opus_prefix/include -I$opus_prefix/include/opus"
    export LDFLAGS="$LDFLAGS -L$ogg_prefix/lib -L$opus_prefix/lib"
    export DEPS_CFLAGS="-I$ogg_prefix/include -I$opus_prefix/include -I$opus_prefix/include/opus"
    export DEPS_LIBS="-L$ogg_prefix/lib -L$opus_prefix/lib -lopus -logg"

    run_configure_make_install "$OPUSFILE_DIR" "$opusfile_build_dir" "$opusfile_prefix" \
        --build="$BUILD_MACHINE" --host="$host" cross_compiling=yes \
        --disable-http --disable-examples

    copy_to_output "macosx" "$arch" "$ogg_prefix" "$opus_prefix" "$opusfile_prefix"
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

    local opus_build_dir="$BUILD_DIR/android/$abi/opus"
    local opus_prefix="$opus_build_dir/install"

    local opusfile_build_dir="$BUILD_DIR/android/$abi/opusfile"
    local opusfile_prefix="$opusfile_build_dir/install"

    # Build ogg first
    echo "Building libogg for Android $abi..."
    run_configure_make_install "$OGG_DIR" "$ogg_build_dir" "$ogg_prefix" \
        --build="$BUILD_MACHINE" --host="$host" cross_compiling=yes

    # Build opus
    echo "Building libopus for Android $abi..."
    run_configure_make_install "$OPUS_DIR" "$opus_build_dir" "$opus_prefix" \
        --build="$BUILD_MACHINE" --host="$host" --disable-extra-programs cross_compiling=yes

    # Build opusfile with ogg and opus dependencies
    echo "Building libopusfile for Android $abi..."
    export PKG_CONFIG_PATH="$ogg_prefix/lib/pkgconfig:$opus_prefix/lib/pkgconfig"
    export CPPFLAGS="-I$ogg_prefix/include -I$opus_prefix/include -I$opus_prefix/include/opus"
    export LDFLAGS="-L$ogg_prefix/lib -L$opus_prefix/lib"
    export DEPS_CFLAGS="-I$ogg_prefix/include -I$opus_prefix/include -I$opus_prefix/include/opus"
    export DEPS_LIBS="-L$ogg_prefix/lib -L$opus_prefix/lib -lopus -logg"

    run_configure_make_install "$OPUSFILE_DIR" "$opusfile_build_dir" "$opusfile_prefix" \
        --build="$BUILD_MACHINE" --host="$host" cross_compiling=yes \
        --disable-http --disable-examples

    copy_to_output "android" "$abi" "$ogg_prefix" "$opus_prefix" "$opusfile_prefix"
}

# ============================================================================
# MAIN
# ============================================================================

echo "============================================"
echo "Building libopus v$OPUS_VERSION, libogg v$OGG_VERSION, libopusfile v$OPUSFILE_VERSION"
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
download_opus
download_opusfile

# Clean source trees if needed
clean_source_tree "$OGG_DIR"
clean_source_tree "$OPUS_DIR"
clean_source_tree "$OPUSFILE_DIR"

# Patch source trees
patch_source_tree "$OGG_DIR"
patch_source_tree "$OPUS_DIR"
patch_source_tree "$OPUSFILE_DIR"

# Create output directory
mkdir -p "$OUTPUT_DIR" "$INCLUDE_OUTPUT_DIR"

# Build iOS (device and simulator)
build_ios iphoneos arm64 aarch64-apple-darwin
build_ios iphonesimulator arm64 aarch64-apple-darwin
build_ios iphonesimulator x86_64 x86_64-apple-darwin
create_fat_binary "iphoneos" "arm64"
create_fat_binary "iphonesimulator" "arm64" "x86_64"

# Build Mac Catalyst (arm64 and x86_64)
build_catalyst arm64 aarch64-apple-darwin
build_catalyst x86_64 x86_64-apple-darwin
create_fat_binary "macosx" "arm64" "x86_64"

# Build Android (4 ABIs)
build_android_abi arm64-v8a   aarch64-linux-android      "aarch64-linux-android${ANDROID_API}"
build_android_abi armeabi-v7a armv7a-linux-androideabi   "armv7a-linux-androideabi${ANDROID_API}"
build_android_abi x86_64      x86_64-linux-android       "x86_64-linux-android${ANDROID_API}"
build_android_abi x86         i686-linux-android         "i686-linux-android${ANDROID_API}"

echo
echo "============================================"
echo "Done building libopus v$OPUS_VERSION, libogg v$OGG_VERSION, libopusfile v$OPUSFILE_VERSION"
echo "============================================"
echo "Artifacts are in: $OUTPUT_DIR"
echo "  Headers:  $INCLUDE_OUTPUT_DIR/{ogg,opus,opusfile}"
echo "  iPhoneOS: $OUTPUT_DIR/iphoneos/{libogg,libopus,libopusfile}.a"
echo "  iOS Sim:  $OUTPUT_DIR/iphonesimulator/{libogg,libopus,libopusfile}.a"
echo "  macOSX:   $OUTPUT_DIR/macosx/{libogg,libopus,libopusfile}.a"
echo "  Android:  $OUTPUT_DIR/android/{arm64-v8a,armeabi-v7a,x86_64,x86}/{libogg,libopus,libopusfile}.a"
echo "============================================"
