#!/usr/bin/env bash
# Builds ogg, opus, opusfile, vorbis and OpenSSL with Conan for each host profile, then lays them
# out where the rest of the pipeline reads them:
#   outputs/android/<abi>/*.a                          Android static libs (android.zip)
#   outputs/{iphoneos,iphonesimulator,macosx}/*.a      one fat .a per SDK (macosx = Catalyst)
#   outputs/include/, outputs/licenses/<package>/
#   build/intermediate/openssl-prebuilt/<variant>/ and include-<variant>/, which
#   scripts/ffmpeg_setup.sh links FFmpeg against
#
# Usage: scripts/conan_build.sh [profile...]   (default: every profile in conan_profiles.sh)
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/conan_env.sh"
cd "$ROOT_DIR"
source scripts/conan_profiles.sh

CONAN_BUILD_DIR="$ROOT_DIR/build/conan"
OUTPUT_DIR="$ROOT_DIR/outputs"
OPENSSL_PREBUILT_DIR="$ROOT_DIR/build/intermediate/openssl-prebuilt"

# library file -> Conan package that ships it
XIPH_LIBS=(libogg:ogg libopus:opus libopusfile:opusfile libvorbis:vorbis libvorbisenc:vorbis libvorbisfile:vorbis)
OPENSSL_LIBS=(libcrypto libssl)
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

# OpenSSL folder names ffmpeg_setup.sh reads.
openssl_variant() {
    case "$1" in
        iphoneos-arm64) echo iphoneos ;;
        iphonesimulator-arm64) echo iphonesimulator ;;
        android-*) echo "${1#android-}" ;;
        *) echo "$1" ;;
    esac
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

for profile in "${deployed[@]}"; do
    variant="$(openssl_variant "$profile")"
    openssl_dir="$(package_dir "$profile" openssl)"
    rm -rf "${OPENSSL_PREBUILT_DIR:?}/$variant" "$OPENSSL_PREBUILT_DIR/include-$variant"
    mkdir -p "$OPENSSL_PREBUILT_DIR/$variant" "$OPENSSL_PREBUILT_DIR/include-$variant"
    for lib in "${OPENSSL_LIBS[@]}"; do
        cp "$openssl_dir/lib/$lib.a" "$OPENSSL_PREBUILT_DIR/$variant/"
    done
    cp -R "$openssl_dir/include/openssl" "$OPENSSL_PREBUILT_DIR/include-$variant/"

    if [[ "$profile" == android-* ]]; then
        dest="$OUTPUT_DIR/android/${profile#android-}"
        mkdir -p "$dest"
        for entry in "${XIPH_LIBS[@]}"; do
            cp "$(package_dir "$profile" "${entry#*:}")/lib/${entry%%:*}.a" "$dest/"
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

# Headers and licenses are the same for every target; take them from the first deployed profile.
first="${deployed[0]}"
mkdir -p "$OUTPUT_DIR/include/opusfile"
cp -R "$(package_dir "$first" ogg)/include/ogg" "$OUTPUT_DIR/include/"
cp -R "$(package_dir "$first" opus)/include/opus" "$OUTPUT_DIR/include/"
cp -R "$(package_dir "$first" vorbis)/include/vorbis" "$OUTPUT_DIR/include/"
cp "$(package_dir "$first" opusfile)/include/opus/opusfile.h" "$OUTPUT_DIR/include/opusfile/"

# outputs/licenses/ffmpeg comes from ffmpeg_setup.sh; replace only the Conan packages' folders.
for package in "${PACKAGES[@]}"; do
    rm -rf "${OUTPUT_DIR:?}/licenses/$package"
    mkdir -p "$OUTPUT_DIR/licenses/$package"
    cp -R "$(package_dir "$first" "$package")/licenses/." "$OUTPUT_DIR/licenses/$package/"
done
if [ -d "$OUTPUT_DIR/android" ]; then
    rm -rf "$OUTPUT_DIR/android/licenses"
    for package in "${PACKAGES[@]}"; do
        mkdir -p "$OUTPUT_DIR/android/licenses"
        cp -R "$OUTPUT_DIR/licenses/$package" "$OUTPUT_DIR/android/licenses/$package"
    done
fi

echo "Conan build finished: ${profiles[*]}"
