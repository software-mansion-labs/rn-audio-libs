# Sourced: the host profiles (conan/profiles/<name>) a full build covers.
CONAN_APPLE_PROFILES=(
    iphoneos-arm64
    iphonesimulator-arm64 iphonesimulator-x86_64
    catalyst-arm64 catalyst-x86_64
    macos-arm64 macos-x86_64
)
CONAN_ANDROID_PROFILES=(android-arm64-v8a android-armeabi-v7a android-x86 android-x86_64)
CONAN_PROFILES=("${CONAN_APPLE_PROFILES[@]}" "${CONAN_ANDROID_PROFILES[@]}")
