#!/usr/bin/env bash
# Builds ogg, opus, opusfile, vorbis, OpenSSL and FFmpeg with Conan for each host profile, then
# lays them out where the pack scripts read them:
#   outputs/android/<abi>/*.a                          Android static libs (android.zip)
#   outputs/{iphoneos,iphonesimulator,macosx}/*.a      one fat .a per SDK (macosx = Catalyst)
#   outputs/jniLibs/<abi>/*.so                         FFmpeg for Android (jniLibs.zip)
#   outputs/ffmpeg_ios/<lib>.xcframework               FFmpeg for iOS, simulator and Catalyst
#   outputs/include_ffmpeg/                            FFmpeg headers (include_ffmpeg.zip)
#   outputs/include/, outputs/licenses/<package>/
#
# Usage: scripts/conan_build.sh [profile...]   (default: every profile in conan_profiles.sh)
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/conan_env.sh"
cd "$ROOT_DIR"
source scripts/conan_profiles.sh

CONAN_BUILD_DIR="$ROOT_DIR/build/conan"
OUTPUT_DIR="$ROOT_DIR/outputs"
# FFmpeg dylibs per SDK, as create_xcframework.sh reads them: <sdk dir>/lib/<lib>.dylib
FFMPEG_STAGING_DIR="$ROOT_DIR/build/intermediate/ffmpeg"

# library file -> Conan package that ships it
XIPH_LIBS=(libogg:ogg libopus:opus libopusfile:opusfile libvorbis:vorbis libvorbisenc:vorbis libvorbisfile:vorbis)
FFMPEG_LIBS=(libavcodec libavformat libavutil libswresample)
# The packages whose licenses android.zip carries; FFmpeg's travel with the FFmpeg assets.
PACKAGES=(ogg opus opusfile vorbis openssl)

if (($#)); then
    profiles=("$@")
else
    profiles=("${CONAN_PROFILES[@]}")
fi

# configs.json pins the NDK and API level. Profiles can't read JSON, so check that
# conan/profiles/android.base names the same API level and the clang major of that NDK.
if [[ " ${profiles[*]} " == *" android-"* ]]; then
    read -r REQUIRED_NDK_VERSION ANDROID_API_LEVEL < <(python3 -c "import json; a=json.load(open('configs.json'))['android']; print(a['ndk'], a['api_level'])")
    ndk="${ANDROID_NDK_ROOT:-${ANDROID_NDK:-}}"
    ndk_version="$(sed -n 's/^Pkg.Revision *= *//p' "$ndk/source.properties" 2>/dev/null || true)"
    if [ "$ndk_version" != "$REQUIRED_NDK_VERSION" ]; then
        echo "Error: configs.json pins NDK $REQUIRED_NDK_VERSION; ANDROID_NDK_ROOT has '${ndk_version:-none}' (${ndk:-unset})" >&2
        exit 1
    fi
    export ANDROID_NDK_ROOT="$ndk"

    ndk_clang="$("$ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/clang" --version | sed -nE 's/.*clang version ([0-9]+).*/\1/p')"
    profile_clang="$(sed -n 's/^compiler.version=//p' conan/profiles/android.base)"
    profile_api="$(sed -n 's/^os.api_level=//p' conan/profiles/android.base)"
    if [ "$profile_clang" != "$ndk_clang" ]; then
        echo "Error: NDK $REQUIRED_NDK_VERSION ships clang $ndk_clang; set compiler.version=$ndk_clang in conan/profiles/android.base" >&2
        exit 1
    fi
    if [ "$profile_api" != "$ANDROID_API_LEVEL" ]; then
        echo "Error: configs.json sets Android API $ANDROID_API_LEVEL; set os.api_level=$ANDROID_API_LEVEL in conan/profiles/android.base" >&2
        exit 1
    fi
    # The android-<abi> profiles name FFmpeg's compiler as the NDK's <triple><api>-clang wrapper.
    stale_profiles="$(grep -LE "android(eabi)?${ANDROID_API_LEVEL}-clang\"" conan/profiles/android-* || true)"
    if [ -n "$stale_profiles" ]; then
        echo "Error: set the FFmpeg compiler to the API $ANDROID_API_LEVEL clang wrapper in: $stale_profiles" >&2
        exit 1
    fi
fi

# The deployed package folder: build/conan/<profile>/full_deploy/host/<package>/<version>/<build_type>/<arch>
package_dir() {
    local matches=("$CONAN_BUILD_DIR/$1"/full_deploy/host/"$2"/*/*/*)
    if [ "${#matches[@]}" -ne 1 ] || [ ! -d "${matches[0]}" ]; then
        echo "Error: expected one deployed $2 package for $1, found: ${matches[*]}" >&2
        exit 1
    fi
    echo "${matches[0]}"
}

for profile in "${profiles[@]}"; do
    echo "=== conan install: $profile ==="
    rm -rf "${CONAN_BUILD_DIR:?}/$profile"
    conan install . -pr:h "conan/profiles/$profile" -pr:b default \
        --lockfile conan.lock --build=missing \
        --output-folder "$CONAN_BUILD_DIR/$profile" \
        --deployer=full_deploy --deployer-folder "$CONAN_BUILD_DIR/$profile"
done

# Lay out every deployed profile, not only this run's, so a partial rebuild keeps the rest.
deployed=()
for profile in "${CONAN_PROFILES[@]}"; do
    [ -d "$CONAN_BUILD_DIR/$profile/full_deploy" ] && deployed+=("$profile")
done

# The NDK's CMake toolchain compiles with -g, so the Android libraries (and the OpenSSL and zlib
# linked into FFmpeg) carry debug info the old builds never shipped; strip it, keeping symbols.
llvm_strip="${ANDROID_NDK_ROOT:-${ANDROID_NDK:-}}/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip"

for profile in "${deployed[@]}"; do
    if [[ "$profile" == android-* ]]; then
        if [ ! -x "$llvm_strip" ]; then
            echo "Error: laying out $profile needs llvm-strip from the NDK; set ANDROID_NDK_ROOT" >&2
            exit 1
        fi
        abi="${profile#android-}"
        mkdir -p "$OUTPUT_DIR/android/$abi"
        for entry in "${XIPH_LIBS[@]}"; do
            cp "$(package_dir "$profile" "${entry#*:}")/lib/${entry%%:*}.a" "$OUTPUT_DIR/android/$abi/"
            "$llvm_strip" --strip-debug "$OUTPUT_DIR/android/$abi/${entry%%:*}.a"
        done
        rm -rf "${OUTPUT_DIR:?}/jniLibs/$abi"
        mkdir -p "$OUTPUT_DIR/jniLibs/$abi"
        for lib in "${FFMPEG_LIBS[@]}"; do
            cp "$(package_dir "$profile" ffmpeg)/lib/$lib.so" "$OUTPUT_DIR/jniLibs/$abi/"
            "$llvm_strip" --strip-debug "$OUTPUT_DIR/jniLibs/$abi/$lib.so"
        done
    fi
done

# One fat .a per SDK, from whichever of its slices are deployed (verify_outputs.sh checks all are).
create_fat_libs() {
    local sdk="$1"
    shift
    local slices=()
    local profile
    for profile in "$@"; do
        [ -d "$CONAN_BUILD_DIR/$profile/full_deploy" ] && slices+=("$profile")
    done
    ((${#slices[@]})) || return 0

    mkdir -p "$OUTPUT_DIR/$sdk"
    local entry
    for entry in "${XIPH_LIBS[@]}"; do
        local inputs=()
        for profile in "${slices[@]}"; do
            inputs+=("$(package_dir "$profile" "${entry#*:}")/lib/${entry%%:*}.a")
        done
        # A single slice stays a plain archive, as the old scripts left it.
        if [ "${#inputs[@]}" -eq 1 ]; then
            cp "${inputs[0]}" "$OUTPUT_DIR/$sdk/${entry%%:*}.a"
        else
            lipo -create "${inputs[@]}" -output "$OUTPUT_DIR/$sdk/${entry%%:*}.a"
        fi
    done
    echo "outputs/$sdk: ${slices[*]}"
}
create_fat_libs iphoneos iphoneos-arm64
create_fat_libs iphonesimulator iphonesimulator-arm64 iphonesimulator-x86_64
create_fat_libs macosx catalyst-arm64 catalyst-x86_64

# The FFmpeg dylibs of one SDK, merged into one fat dylib per library under the unversioned name.
# Returns 1 when none of the SDK's slices is deployed.
stage_ffmpeg_dylibs() {
    local dir="$FFMPEG_STAGING_DIR/$1/lib"
    shift
    local slices=()
    local profile
    for profile in "$@"; do
        [ -d "$CONAN_BUILD_DIR/$profile/full_deploy" ] && slices+=("$profile")
    done
    ((${#slices[@]})) || return 1

    mkdir -p "$dir"
    local lib
    for lib in "${FFMPEG_LIBS[@]}"; do
        local inputs=()
        for profile in "${slices[@]}"; do
            inputs+=("$(package_dir "$profile" ffmpeg)/lib/$lib.dylib")
        done
        # lipo and cp -L both follow the <lib>.dylib -> <lib>.<version>.dylib symlink.
        if [ "${#inputs[@]}" -eq 1 ]; then
            cp -L "${inputs[0]}" "$dir/$lib.dylib"
        else
            lipo -create "${inputs[@]}" -output "$dir/$lib.dylib"
        fi
    done
}
rm -rf "$FFMPEG_STAGING_DIR"
if stage_ffmpeg_dylibs ios/iphoneos iphoneos-arm64 &&
    stage_ffmpeg_dylibs ios/iphonesimulator iphonesimulator-arm64 iphonesimulator-x86_64 &&
    stage_ffmpeg_dylibs catalyst/fat catalyst-arm64 catalyst-x86_64; then
    # Wraps each dylib in a .framework (install names -> @rpath/<lib>.framework/<lib>).
    rm -rf "$OUTPUT_DIR/ffmpeg_ios"
    FFMPEG_FRAMEWORK_SOURCE_DIR="$FFMPEG_STAGING_DIR" FFMPEG_XCFRAMEWORK_OUTPUT_DIR="$OUTPUT_DIR/ffmpeg_ios" \
        bash scripts/create_xcframework.sh
else
    echo "Skipping the FFmpeg xcframeworks: they need the iphoneos, iphonesimulator and catalyst profiles."
fi

# Headers and licenses are the same for every target; take them from the first deployed profile.
first="${deployed[0]}"
mkdir -p "$OUTPUT_DIR/include/opusfile"
cp -R "$(package_dir "$first" ogg)/include/ogg" "$OUTPUT_DIR/include/"
cp -R "$(package_dir "$first" opus)/include/opus" "$OUTPUT_DIR/include/"
cp -R "$(package_dir "$first" vorbis)/include/vorbis" "$OUTPUT_DIR/include/"
cp "$(package_dir "$first" opusfile)/include/opus/opusfile.h" "$OUTPUT_DIR/include/opusfile/"

# FFmpeg headers, adjusted for react-native-audio-api: libavutil/time.h would shadow the system
# <time.h> on a recursive include path, and AVMediaType collides with AVFoundation's.
ffmpeg_dir="$(package_dir "$first" ffmpeg)"
rm -rf "$OUTPUT_DIR/include_ffmpeg"
mkdir -p "$OUTPUT_DIR/include_ffmpeg"
for lib in "${FFMPEG_LIBS[@]}"; do
    cp -R "$ffmpeg_dir/include/$lib" "$OUTPUT_DIR/include_ffmpeg/"
done
rm -f "$OUTPUT_DIR/include_ffmpeg/libavutil/time.h"
grep -rl -- "AVMediaType" "$OUTPUT_DIR/include_ffmpeg" | while IFS= read -r header; do
    perl -pi -e 's/AVMediaType/AVMediaTypeFFmpeg/g' "$header"
done

rm -rf "$OUTPUT_DIR/licenses"
for package in "${PACKAGES[@]}" zlib ffmpeg; do
    mkdir -p "$OUTPUT_DIR/licenses/$package"
    cp -R "$(package_dir "$first" "$package")/licenses/." "$OUTPUT_DIR/licenses/$package/"
done
# The ffmpeg package ships only LICENSE.md, which refers to the LGPL texts next to it in the source.
ffmpeg_source="$(conan cache path "ffmpeg/$(python3 -c "import json; print(json.load(open('configs.json'))['ffmpeg']['version'])")" --folder source)"
# The recipe unpacks the sources into src/ of its source folder.
cp "$ffmpeg_source/src/COPYING.LGPLv2.1" "$ffmpeg_source/src/COPYING.LGPLv3" "$OUTPUT_DIR/licenses/ffmpeg/"
# Android's FFmpeg download is jniLibs.zip + include_ffmpeg.zip, and jniLibs/ holds only libraries,
# so the headers carry the licenses of what the .so files contain.
mkdir -p "$OUTPUT_DIR/include_ffmpeg/licenses"
for package in ffmpeg openssl zlib; do
    cp -R "$OUTPUT_DIR/licenses/$package" "$OUTPUT_DIR/include_ffmpeg/licenses/$package"
done
if [ -d "$OUTPUT_DIR/android" ]; then
    rm -rf "$OUTPUT_DIR/android/licenses"
    for package in "${PACKAGES[@]}"; do
        mkdir -p "$OUTPUT_DIR/android/licenses"
        cp -R "$OUTPUT_DIR/licenses/$package" "$OUTPUT_DIR/android/licenses/$package"
    done
fi

echo "Conan build finished: ${profiles[*]}"
