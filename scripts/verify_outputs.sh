#!/usr/bin/env bash
# Checks the built libraries before they are packed or released; exits non-zero on any mismatch.
#   - Apple: lipo architectures per SDK, and vtool's LC_BUILD_VERSION (platform, minos) for every
#     object of every slice in outputs/{iphoneos,iphonesimulator,macosx} and for every slice of
#     the FFmpeg frameworks in outputs/ffmpeg_ios
#   - Android: llvm-readelf ELF class/machine for every object in outputs/android/<abi> and for
#     the FFmpeg .so files in outputs/jniLibs/<abi> (plus their 16 KB segment alignment)
#   - nm: each library defines its entry points (opus_decode, avformat_open_input, ...)
#   - FFmpeg links only system libraries and its own; OpenSSL (configs.json version) is inside
#   - --release: export/ holds exactly the release assets, with the archive layout
#     react-native-audio-api downloads, and checksums.txt matches them
#
# Usage: scripts/verify_outputs.sh [--release] [profile...]   (default: every profile)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source scripts/conan_profiles.sh

IOS_MIN_VERSION="15.1"
OUTPUT_DIR="outputs"
EXPORT_DIR="export"
OPENSSL_VERSION="$(python3 -c "import json; print(json.load(open('configs.json'))['openssl']['version'])")"

XIPH_LIBS=(libogg libopus libopusfile libvorbis libvorbisenc libvorbisfile)
ANDROID_ABIS=(arm64-v8a armeabi-v7a x86 x86_64)
FFMPEG_FRAMEWORKS=(libavcodec libavformat libavutil libswresample)
XCFRAMEWORK_SLICES=(ios-arm64 ios-arm64_x86_64-simulator ios-arm64_x86_64-maccatalyst)

release=false
if [ "${1:-}" = "--release" ]; then
    release=true
    shift
fi
if (($#)); then
    profiles=("$@")
else
    profiles=("${CONAN_PROFILES[@]}")
fi

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

ndk="${ANDROID_NDK_ROOT:-${ANDROID_NDK:-}}"
LLVM_BIN="$ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A symbol each library must define, so a truncated or wrong archive cannot pass.
entry_symbol() {
    case "$1" in
        libogg) echo ogg_sync_init ;;
        libopus) echo opus_decode ;;
        libopusfile) echo op_open_callbacks ;;
        libvorbis) echo vorbis_info_init ;;
        libvorbisenc) echo vorbis_encode_init ;;
        libvorbisfile) echo ov_open_callbacks ;;
        libavcodec) echo avcodec_open2 ;;
        libavformat) echo avformat_open_input ;;
        libavutil) echo av_malloc ;;
        libswresample) echo swr_init ;;
    esac
}

# FFmpeg's OpenSSL is linked in statically; its version string proves which one.
check_openssl_inside() {
    local binary="$1"
    local strings_out
    strings_out="$(strings "$binary" 2>/dev/null)"
    grep -q "OpenSSL $OPENSSL_VERSION " <<<"$strings_out" || fail "$binary does not contain OpenSSL $OPENSSL_VERSION"
}

# check_apple_dylib <binary> <arch> <platform> <minos>: one slice of an FFmpeg framework.
check_apple_dylib() {
    local binary="$1" arch="$2" platform="$3" minos="$4"
    local lib
    lib="$(basename "$binary")"
    if [ ! -f "$binary" ]; then
        fail "$binary missing"
        return
    fi
    if ! lipo "$binary" -verify_arch "$arch"; then
        fail "$binary has no $arch slice ($(lipo -archs "$binary"))"
        return
    fi
    local build deps symbols
    build="$(vtool -arch "$arch" -show-build "$binary")"
    if ! grep -q "platform $platform\$" <<<"$build" || ! grep -q "minos $minos\$" <<<"$build"; then
        fail "$binary ($arch): expected $platform minos $minos, got: $(grep -E 'platform|minos' <<<"$build" | tr -s ' \n' ' ')"
    fi
    # Only the system and the other FFmpeg frameworks: OpenSSL and zlib are linked in.
    deps="$(otool -arch "$arch" -L "$binary" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/|@rpath/lib(avcodec|avformat|avutil|swresample)\.framework/)' || true)"
    [ -z "$deps" ] || fail "$binary ($arch) links unexpected libraries: $(echo $deps)"
    symbols="$(nm -g --defined-only -arch "$arch" "$binary" 2>/dev/null)"
    grep -qw "_$(entry_symbol "$lib")" <<<"$symbols" || fail "$binary ($arch) does not define $(entry_symbol "$lib")"
}

# check_android_so <binary> <abi>: one FFmpeg .so.
check_android_so() {
    local binary="$1" abi="$2"
    local lib
    lib="$(basename "$binary" .so)"
    if [ ! -f "$binary" ]; then
        fail "$binary missing"
        return
    fi
    check_android "$binary" "$abi" "$lib"
    local alignments needed
    alignments="$("$LLVM_BIN/llvm-readelf" -l "$binary" | awk '/LOAD/{print $NF}' | sort -u | tr '\n' ' ')"
    [ "$alignments" = "0x4000 " ] || fail "$binary: LOAD segments aligned $alignments, expected 0x4000 (16 KB pages)"
    needed="$("$LLVM_BIN/llvm-readelf" -d "$binary" | sed -nE 's/.*\(NEEDED\).*\[(.*)\]/\1/p' | grep -vxE 'lib(avcodec|avformat|avutil|swresample|c|m|dl|log)\.so' || true)"
    [ -z "$needed" ] || fail "$binary links unexpected libraries: $(echo $needed)"
}

# Extracts the objects of one architecture of <archive> into a fresh folder and prints its path.
extract_objects() {
    local archive="$1" arch="$2"
    local dir="$work/objects"
    rm -rf "$dir"
    mkdir -p "$dir"
    # lipo -thin refuses a non-fat archive; that one is already the slice.
    lipo -thin "$arch" "$archive" -output "$dir/thin.a" 2>/dev/null || cp "$archive" "$dir/thin.a"
    (cd "$dir" && ar -x thin.a && rm thin.a)
    echo "$dir"
}

# check_apple <archive> <arch> <platform> <minos>
check_apple() {
    local archive="$1" arch="$2" platform="$3" minos="$4"
    local lib
    lib="$(basename "$archive" .a)"
    if [ ! -f "$archive" ]; then
        fail "$archive missing"
        return
    fi
    if ! lipo "$archive" -verify_arch "$arch"; then
        fail "$archive has no $arch slice ($(lipo -archs "$archive"))"
        return
    fi
    local objects object build symbols
    objects="$(extract_objects "$archive" "$arch")"
    for object in "$objects"/*.o; do
        build="$(vtool -show-build "$object")"
        if ! grep -q "platform $platform\$" <<<"$build" || ! grep -q "minos $minos\$" <<<"$build"; then
            fail "$archive ($arch) $(basename "$object"): expected $platform minos $minos, got: $(grep -E 'platform|minos' <<<"$build" | tr -s ' \n' ' ')"
            return
        fi
    done
    # Not `nm | grep -q`: grep exiting early makes nm fail with SIGPIPE under pipefail.
    symbols="$(nm -g --defined-only -arch "$arch" "$archive" 2>/dev/null)"
    if ! grep -qw "_$(entry_symbol "$lib")" <<<"$symbols"; then
        fail "$archive ($arch) does not define $(entry_symbol "$lib")"
    fi
}

# check_android <archive or .so> <abi> [library name]
check_android() {
    local archive="$1" abi="$2"
    local lib="${3:-$(basename "$archive" .a)}"
    local class machine
    case "$abi" in
        arm64-v8a) class=ELF64 machine="AArch64" ;;
        armeabi-v7a) class=ELF32 machine="ARM" ;;
        x86) class=ELF32 machine="Intel 80386" ;;
        x86_64) class=ELF64 machine="Advanced Micro Devices X86-64" ;;
    esac
    if [ ! -f "$archive" ]; then
        fail "$archive missing"
        return
    fi
    local headers sections
    headers="$("$LLVM_BIN/llvm-readelf" -h "$archive")"
    sections="$("$LLVM_BIN/llvm-readelf" -S "$archive")"
    grep -q '\.debug_' <<<"$sections" && fail "$archive: carries debug info (conan_build.sh strips it)"
    if grep -E '^ *(Class|Machine):' <<<"$headers" | sed -E 's/^ *(Class|Machine): *//' | sort -u \
        | grep -vqxE "$class|$machine"; then
        fail "$archive: expected $class $machine, found $(grep -E '^ *(Class|Machine):' <<<"$headers" | sed -E 's/^ *(Class|Machine): *//' | sort -u | tr '\n' ',')"
    fi
    local symbols
    # A shared library's exported symbols are its dynamic ones (the static table may be stripped).
    local nm_scope=-g
    [[ "$archive" == *.so ]] && nm_scope=-D
    symbols="$("$LLVM_BIN/llvm-nm" "$nm_scope" --defined-only "$archive" 2>/dev/null)"
    if ! grep -qw "$(entry_symbol "$lib")" <<<"$symbols"; then
        fail "$archive does not define $(entry_symbol "$lib")"
    fi
}

# Expected architectures of each fat SDK library: those of the profiles being verified.
expected_iphoneos=()
expected_iphonesimulator=()
expected_macosx=()

for profile in "${profiles[@]}"; do
    echo "--- $profile"
    case "$profile" in
        android-*)
            abi="${profile#android-}"
            if [ ! -x "$LLVM_BIN/llvm-readelf" ]; then
                fail "llvm-readelf not found; set ANDROID_NDK_ROOT"
                continue
            fi
            for lib in "${XIPH_LIBS[@]}"; do
                check_android "$OUTPUT_DIR/android/$abi/$lib.a" "$abi"
            done
            for lib in "${FFMPEG_FRAMEWORKS[@]}"; do
                check_android_so "$OUTPUT_DIR/jniLibs/$abi/$lib.so" "$abi"
            done
            check_openssl_inside "$OUTPUT_DIR/jniLibs/$abi/libavformat.so"
            continue
            ;;
    esac

    arch="${profile##*-}"
    # sdk: the outputs/ folder of the static libs; slice: the FFmpeg xcframework slice's suffix.
    case "$profile" in
        iphoneos-*) sdk=iphoneos platform=IOS slice="" ;;
        iphonesimulator-*) sdk=iphonesimulator platform=IOSSIMULATOR slice="-simulator" ;;
        catalyst-*) sdk=macosx platform=MACCATALYST slice="-maccatalyst" ;;
        *) fail "unknown profile $profile"; continue ;;
    esac

    eval "expected_$sdk+=(\"$arch\")"
    for lib in "${XIPH_LIBS[@]}"; do
        check_apple "$OUTPUT_DIR/$sdk/$lib.a" "$arch" "$platform" "$IOS_MIN_VERSION"
    done
    for lib in "${FFMPEG_FRAMEWORKS[@]}"; do
        slice_dirs=("$OUTPUT_DIR/ffmpeg_ios/$lib.xcframework"/ios-*"$slice")
        [ "$slice" = "" ] && slice_dirs=("$OUTPUT_DIR/ffmpeg_ios/$lib.xcframework"/ios-arm64)
        # Catalyst frameworks use the versioned bundle layout; <lib> links to Versions/A/<lib>.
        check_apple_dylib "${slice_dirs[0]}/$lib.framework/$lib" "$arch" "$platform" "$IOS_MIN_VERSION"
        [ "$lib" = libavformat ] && check_openssl_inside "${slice_dirs[0]}/$lib.framework/$lib"
    done
done

echo "--- fat SDK libraries"
for sdk in iphoneos iphonesimulator macosx; do
    eval "expected=(\${expected_$sdk[@]+\"\${expected_$sdk[@]}\"})"
    ((${#expected[@]})) || continue
    want="$(printf '%s\n' "${expected[@]}" | sort | tr '\n' ' ')"
    for lib in "${XIPH_LIBS[@]}"; do
        archive="$OUTPUT_DIR/$sdk/$lib.a"
        [ -f "$archive" ] || continue
        got="$(lipo -archs "$archive" | tr ' ' '\n' | sort | tr '\n' ' ')"
        [ "$got" = "$want" ] || fail "$archive: expected architectures '$want', found '$got'"
    done
done

# Prints the sorted file list (no directories) of <zip>. Callers grep its captured output:
# `zip_files | grep -q` would fail under pipefail when grep exits early.
zip_files() {
    unzip -Z1 "$1" | grep -v '/$' | sort
}

if [ "$release" = true ]; then
    echo "--- release assets"
    expected_assets="$(printf '%s\n' android.zip jniLibs.zip include_ffmpeg.zip | sort)"
    actual_assets="$(cd "$EXPORT_DIR" && find . -maxdepth 1 -name '*.zip' -exec basename {} \; | grep -xE 'android.zip|jniLibs.zip|include_ffmpeg.zip' | sort || true)"
    [ "$actual_assets" = "$expected_assets" ] || fail "export/: expected $(echo $expected_assets), found $(echo $actual_assets)"

    spm_names=("${XIPH_LIBS[@]}" "${FFMPEG_FRAMEWORKS[@]}" FFmpegHeaders)
    expected_spm="$(printf '%s.xcframework.zip\n' "${spm_names[@]}" | sort)"
    actual_spm="$(cd "$EXPORT_DIR/spm" && ls *.xcframework.zip | sort)"
    [ "$actual_spm" = "$expected_spm" ] || fail "export/spm/: expected $(echo $expected_spm), found $(echo $actual_spm)"

    # android.zip: android/<abi>/<lib>.a for every ABI and library, plus licenses/.
    expected_android="$(for abi in "${ANDROID_ABIS[@]}"; do for lib in "${XIPH_LIBS[@]}"; do echo "android/$abi/$lib.a"; done; done | sort)"
    actual_android="$(zip_files "$EXPORT_DIR/android.zip" | grep -v '^android/licenses/')"
    [ "$actual_android" = "$expected_android" ] || fail "android.zip layout: $(diff <(echo "$expected_android") <(echo "$actual_android") | tr '\n' ' ')"
    android_files="$(zip_files "$EXPORT_DIR/android.zip")"
    for package in ogg opus opusfile vorbis openssl; do
        grep -q "^android/licenses/$package/" <<<"$android_files" || fail "android.zip has no licenses/$package"
    done

    # jniLibs.zip: jniLibs/<abi>/<lib>.so; include_ffmpeg.zip: the FFmpeg umbrella headers.
    jnilibs_files="$(zip_files "$EXPORT_DIR/jniLibs.zip")"
    ffmpeg_header_files="$(zip_files "$EXPORT_DIR/include_ffmpeg.zip")"
    for abi in "${ANDROID_ABIS[@]}"; do
        for lib in "${FFMPEG_FRAMEWORKS[@]}"; do
            grep -qx "jniLibs/$abi/$lib.so" <<<"$jnilibs_files" || fail "jniLibs.zip has no jniLibs/$abi/$lib.so"
        done
    done
    for header in libavcodec/avcodec.h libavformat/avformat.h libavutil/avutil.h libswresample/swresample.h; do
        grep -qx "include_ffmpeg/$header" <<<"$ffmpeg_header_files" || fail "include_ffmpeg.zip has no $header"
    done
    # Android's FFmpeg download is jniLibs.zip + include_ffmpeg.zip; the headers carry the
    # licenses (jniLibs/ is Gradle's native-library folder).
    for package in ffmpeg openssl zlib; do
        grep -q "^include_ffmpeg/licenses/$package/" <<<"$ffmpeg_header_files" || fail "include_ffmpeg.zip has no licenses/$package"
    done

    # Static xcframeworks: <lib>.xcframework/<slice>/<lib>.a for the device, simulator and
    # Catalyst slices; every xcframework carries its licenses.
    for lib in "${XIPH_LIBS[@]}"; do
        expected_xcf="$( (echo "$lib.xcframework/Info.plist"; for slice in "${XCFRAMEWORK_SLICES[@]}"; do echo "$lib.xcframework/$slice/$lib.a"; done) | sort)"
        actual_xcf="$(zip_files "$EXPORT_DIR/spm/$lib.xcframework.zip" | grep -v "^$lib.xcframework/licenses/")"
        [ "$actual_xcf" = "$expected_xcf" ] || fail "$lib.xcframework.zip layout: $(diff <(echo "$expected_xcf") <(echo "$actual_xcf") | tr '\n' ' ')"
    done
    # Every xcframework carries the licenses of what it contains.
    for name in "${spm_names[@]}"; do
        case "$name" in
            libopusfile) packages=opusfile ;;
            libopus) packages=opus ;;
            libogg) packages=ogg ;;
            libvorbis*) packages=vorbis ;;
            FFmpegHeaders) packages=ffmpeg ;;
            *) packages="ffmpeg openssl zlib" ;;
        esac
        xcf_files="$(zip_files "$EXPORT_DIR/spm/$name.xcframework.zip")"
        for package in $packages; do
            grep -q "^$name.xcframework/licenses/$package/" <<<"$xcf_files" || fail "$name.xcframework.zip has no licenses/$package"
        done
    done

    # checksums.txt: one "<name> <sha256>" line per xcframework, matching the archive.
    [ "$(wc -l <"$EXPORT_DIR/spm/checksums.txt" | tr -d ' ')" = "${#spm_names[@]}" ] || fail "checksums.txt: expected ${#spm_names[@]} lines"
    while read -r name checksum; do
        actual="$(shasum -a 256 "$EXPORT_DIR/spm/$name.xcframework.zip" | cut -d' ' -f1)"
        [ "$actual" = "$checksum" ] || fail "checksums.txt: $name is $checksum, archive is $actual"
    done <"$EXPORT_DIR/spm/checksums.txt"
fi

if ((failures)); then
    echo "Verification failed: $failures problem(s)" >&2
    exit 1
fi
echo "Verification passed: ${profiles[*]}$([ "$release" = true ] && echo ' + release assets')"
