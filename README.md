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
excluding `include` (those Ogg/Opus/Vorbis headers are tracked in
`react-native-audio-api`).

For iOS, also run:

```bash
bash scripts/pack_spm_xcframeworks.sh
```

This creates `export/spm/<name>.xcframework.zip`, one per library, plus
`checksums.txt`. CocoaPods and Swift Package Manager both consume these.

A release needs these archives attached as assets, because
`react-native-audio-api` pins the tag (`download-prebuilt-binaries.sh` and
`Package.swift`) and fails on a missing one:

- `android.zip`: Android static libs
- `libopus`, `libopusfile`, `libogg`, `libvorbis`, `libvorbisenc`,
  `libvorbisfile` `.xcframework.zip`: iOS static libs
- `jniLibs.zip`, `include_ffmpeg.zip`, and `libavcodec`, `libavformat`,
  `libavutil`, `libswresample`, `FFmpegHeaders` `.xcframework.zip`: FFmpeg,
  only fetched when FFmpeg is enabled

Repacking changes every checksum, and Swift Package Manager rejects an asset
whose checksum changed under the same URL, so publish rebuilt archives under a
new tag. Copy the new `checksums.txt` values into `Package.swift`.
