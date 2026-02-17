# rn-audio-libs

This repository builds and packages native audio dependencies used by
[`react-native-audio-api`](https://github.com/software-mansion/react-native-audio-api).

Library versions are configured in `configs.json`.

## Included Libraries

- FFmpeg (LGPLv3): [lgplv3.txt](lgplv3.txt)
- OpenSSL (Apache-2.0): [apache2.txt](apache2.txt)
- LibOpus (BSD): [bsd3opus.txt](bsd3opus.txt)
- LibOgg (BSD): [bsd3ogg.txt](bsd3ogg.txt)
- LibVorbis (BSD): [bsd3ogg.txt](bsd3ogg.txt)

## Requirements

- macOS + Xcode command line tools (required for Apple builds)
- `yarn`
- `zip` (for export packaging)
- `ANDROID_NDK_ROOT` (or `ANDROID_NDK`) for Android builds

## Scripts

All scripts are in `scripts/`.

### Main yarn commands

- `yarn build:opus`: builds Ogg/Opus/Opusfile static libs
- `yarn build:vorbis`: builds Ogg/Vorbis static libs
- `yarn build:ffmpeg`: builds FFmpeg (+OpenSSL dependencies) and XCFrameworks
- `yarn build`: runs `clean` + all build scripts
- `yarn export`: zips built outputs into `export/`
- `yarn clean`: removes `outputs/*`, `sources/*`, `build/*`

### Direct script entrypoints

- `scripts/bundle_opus.sh`
- `scripts/bundle_vorbis.sh`
- `scripts/ffmpeg_setup.sh`
- `scripts/create_xcframework.sh` (invoked by `ffmpeg_setup.sh`)
- `scripts/pack_outputs.sh`

## Output Layout

Build artifacts are written to `outputs/`:

- `outputs/include/`
  - public headers for `ogg`, `opus`, `opusfile`, `vorbis`, `openssl`
- `outputs/include_ffmpeg/`
  - FFmpeg headers
- `outputs/android/<abi>/`
  - static libs from opus/vorbis scripts
  - OpenSSL static libs copied by FFmpeg script
- `outputs/iphoneos/`
  - fat Apple static libs for device (`.a`)
  - OpenSSL `libcrypto.a`, `libssl.a`
- `outputs/iphonesimulator/`
  - fat Apple static libs for simulator (`.a`)
  - OpenSSL `libcrypto.a`, `libssl.a`
- `outputs/macosx/`
  - fat Apple static libs for Catalyst/macOSX target (`.a`)
  - OpenSSL `libcrypto.a`, `libssl.a`
- `outputs/jniLibs/<abi>/`
  - FFmpeg Android shared libs (`.so`)
- `outputs/ffmpeg_ios/`
  - FFmpeg XCFrameworks (device + simulator + catalyst slices)

## Intermediate Build Files

- Intermediate data is kept under `build/intermediate/`.
- Build scripts do not purge `build/intermediate` automatically.

## Export Packaging

Run:

```bash
yarn export
```

This creates `export/*.zip`, one archive per top-level directory in `outputs/`,
excluding `include` and `include_ffmpeg`.
