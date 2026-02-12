This repository contains cross-compiled libraries needed for [`react-native-audio-api`](https://github.com/software-mansion/react-native-audio-api) project. You can find them in assets attached to the release f.e. https://github.com/software-mansion-labs/rn-audio-libs/releases/tag/v1.0.0.

Additionally, there is a [bash script](ffmpeg_setup.sh), that builds [FFmpeg](https://github.com/FFmpeg/FFmpeg) as dynamic libraries for Android and iOS architectures.

It contains:

- FFmpeg binaries, under [LGPLv3.0 license](lgplv3.txt)
- OpenSSL binaries, under [Apache-2.0 license](apache2.txt)
- LibOpus, under [BSD license](bsd3opus.txt)
- LibOgg, under [BSD license](bsd3ogg.txt)

## Building Libraries

Library versions are configured in `configs.json`.

### LibOpus

```bash
yarn build:opus
# or
./scripts/bundle_opus.sh
```

Builds libopus for macOS (arm64, x86_64), iOS (device + simulator), and Android (arm64-v8a, armeabi-v7a, x86_64, x86). Output: `outputs/opus/`

### LibVorbis (with LibOgg)

```bash
yarn build:vorbis
# or
./scripts/bundle_vorbis.sh
```

Builds libvorbis and libogg for macOS (arm64, x86_64), iOS (device + simulator), and Android (arm64-v8a, armeabi-v7a, x86_64, x86). Output: `outputs/vorbis/`

**Note:** Android builds require `ANDROID_NDK_ROOT` environment variable to be set.
