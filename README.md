# rn-audio-libs

This repository builds and packages native audio dependencies used by
[`react-native-audio-api`](https://github.com/software-mansion/react-native-audio-api).
That repository downloads the release assets at `pod install` / Gradle time
(`scripts/download-prebuilt-binaries.sh`, pinned `TAG`) and through SwiftPM binary targets
(`Package.swift`, pinned checksums). Its users never run anything from here.

Library versions are configured in `configs.json`.

## Included Libraries

- FFmpeg (LGPL 2.1 or later): [lgplv3.txt](lgplv3.txt)
- OpenSSL (Apache-2.0): [apache2.txt](apache2.txt)
- zlib (zlib license), linked into FFmpeg
- LibOpus (BSD): [bsd3opus.txt](bsd3opus.txt)
- LibOgg (BSD): [bsd3ogg.txt](bsd3ogg.txt)
- LibVorbis (BSD): [bsd3ogg.txt](bsd3ogg.txt)

Every library is built with [Conan 2](https://docs.conan.io) from the ConanCenter recipes.
FFmpeg is a set of shared libraries with OpenSSL and zlib linked in statically; its configure
reports the build as "LGPL version 2.1 or later".

License files ship with the binaries, under `licenses/<package>/`, taken from the sources being
built (Conan packages, and FFmpeg's `LICENSE.md` and `COPYING.LGPL*`):

- `android.zip`: ogg, opus, opusfile, vorbis, openssl
- each Ogg/Opus/Vorbis xcframework: its own package
- FFmpeg xcframeworks and `include_ffmpeg.zip`: ffmpeg, openssl and zlib (linked in statically);
  `FFmpegHeaders.xcframework`: ffmpeg. `jniLibs.zip` carries none, as it unpacks into Gradle's
  native-library folder: on Android the FFmpeg licenses come with `include_ffmpeg.zip`.

## Requirements

| Tool | Version | Notes |
| --- | --- | --- |
| macOS + Xcode | 26.6 in CI (`XCODE_APP` in `.github/workflows/release.yml`) | `sudo xcode-select -s /Applications/Xcode_26.6.app` |
| Android NDK | `configs.json` `android.ndk` (27.1.12297006, clang 18) | `sdkmanager "ndk;27.1.12297006"`, then `export ANDROID_NDK_ROOT=$ANDROID_HOME/ndk/27.1.12297006`; the build refuses any other NDK |
| Python | >= 3.10 (`.python-version`: 3.12) | `pyenv install` picks up `.python-version` |
| `yarn` | 4.6 (corepack) | |
| `zip` | | for packing |

Conan itself is not installed globally: `yarn setup:conan` creates a gitignored `.venv/` from
`requirements.txt` (exact versions, verified with `--require-hashes`), and every script uses
`CONAN_HOME=.conan2` inside the repository (gitignored too), so nothing touches `~/.conan2`.

## Building

```bash
yarn setup:conan        # .venv + .conan2 (profile detect, conan/config/global.conf)
yarn build              # clean, then build:conan (every library, FFmpeg included)
yarn export             # export/*.zip and export/spm/*.xcframework.zip + checksums.txt
yarn verify --release   # fails on a wrong slice, platform, min OS, symbol or asset layout
```

`yarn build:conan [profile...]` builds only the given profiles from `conan/profiles/`, and
`yarn verify [profile...]` checks just those, e.g.
`yarn build:conan iphoneos-arm64 android-arm64-v8a`.

### How the Conan build fits together

- `conanfile.py` requires each library at the version from `configs.json`, all static except
  FFmpeg, `opusfile:http=False` (no OpenSSL in opusfile), OpenSSL `no_asm`, `no_zlib` and
  `no_apps`. FFmpeg: `disable_everything` plus the decoders, encoders, demuxers, muxers, parser
  and protocols react-native-audio-api uses (`FFMPEG_COMPONENTS`), `with_ssl=openssl`,
  `with_zlib`, and every other optional library the recipe enables by default turned off
  (`FFMPEG_DISABLED`). ConanCenter keeps only recent FFmpeg versions; `configs.json` must name
  one its `recipes/ffmpeg/config.yml` lists.
- `conan/profiles/`: one host profile per slice. Apple profiles include `apple.base` (the
  detected `default` Mac profile, which is also the build profile); `android-<abi>` include
  `android.base` (API 24, clang 18, `c++_shared`, NDK from `ANDROID_NDK_ROOT`, 16 KB page-size
  link flags). Both bases restore the vorbis flags of the old autotools build (`-fsigned-char`,
  plus `-ffast-math` on Apple), pass FFmpeg's extra configure flags (`--enable-small`,
  `--disable-debug`, no x86 or inline assembly) and make compiler/linker flags part of the
  package ID. FFmpeg's configure ignores the compiler Conan's Android toolchain sets, so each
  `android-<abi>` profile names the NDK's `<triple><api>-clang` for it.
  The list of profiles a full build covers is in `scripts/conan_profiles.sh`.
- `conan.lock` pins every library and build tool (cmake, autotools, pkgconf, ...) to an exact
  version and recipe revision; builds pass `--lockfile conan.lock`, so a recipe update on
  ConanCenter can't change a build until the lockfile is regenerated. Sources are downloaded
  from upstream and checked against the sha256 in the recipe.
- `scripts/conan_build.sh` runs `conan install` with the `full_deploy` deployer into
  `build/conan/<profile>/` and copies the result into the layout below. FFmpeg's dylibs are
  merged per SDK in `build/intermediate/ffmpeg/` and wrapped into frameworks and xcframeworks by
  `scripts/create_xcframework.sh`; its headers get the react-native-audio-api adjustments
  (no `libavutil/time.h`, `AVMediaType` renamed to `AVMediaTypeFFmpeg`).
  The NDK's CMake toolchain always compiles with `-g`, so the Android `.a` and `.so` files are
  stripped of debug info (`llvm-strip --strip-debug`, symbols kept); `verify_outputs.sh` fails
  if any comes back.

## Output Layout

Build artifacts are written to `outputs/`:

- `outputs/include/`: public headers for `ogg`, `opus`, `opusfile`, `vorbis`, `openssl`
- `outputs/include_ffmpeg/`: FFmpeg headers
- `outputs/licenses/<package>/`: license files from the Conan packages and FFmpeg
- `outputs/android/<abi>/`: Ogg/Opus/Vorbis static libs (`android/licenses/` too)
- `outputs/iphoneos/`, `outputs/iphonesimulator/`, `outputs/macosx/` (Catalyst): fat
  Ogg/Opus/Vorbis static libs
- `outputs/jniLibs/<abi>/`: FFmpeg Android shared libs (`.so`)
- `outputs/ffmpeg_ios/`: FFmpeg XCFrameworks (device + simulator + catalyst slices)

Intermediate data is kept under `build/` and not purged automatically.

## Release assets

`react-native-audio-api` pins the tag and fails on a missing asset. A release has exactly:

- `android.zip`: `android/<abi>/<lib>.a` for the 4 ABIs and 6 Ogg/Opus/Vorbis libs
- `libopus`, `libopusfile`, `libogg`, `libvorbis`, `libvorbisenc`, `libvorbisfile`
  `.xcframework.zip`: device, simulator and Catalyst slices
- `jniLibs.zip`, `include_ffmpeg.zip`, and `libavcodec`, `libavformat`, `libavutil`,
  `libswresample`, `FFmpegHeaders` `.xcframework.zip`: FFmpeg
- `checksums.txt`: the SwiftPM checksum of each `.xcframework.zip`

Repacking changes every checksum, and SwiftPM rejects an asset whose checksum changed under
the same URL, so **a tag is never reused**: every rebuild gets a new tag.

## Runbook

### Bumping a library

1. Change the version in `configs.json` (OpenSSL: stay on the 3.5 LTS line, see below).
2. `yarn lock:conan` (with `ANDROID_NDK_ROOT` set). It recreates `conan.lock` across all
   profiles from the latest ConanCenter recipe revisions; to refresh revisions without a version
   change run it as well (`yarn lock:conan --update` also re-checks the remote).
3. Build and verify locally if the change is more than a patch bump, then open a PR with
   `configs.json` and `conan.lock`; review the lockfile diff (new revisions are new recipe code).
4. After merging, run the release workflow (below).

### Changing the Android NDK or API level

`configs.json` `android` holds both: `ndk` (the exact NDK revision, which CI installs) and
`api_level` (react-native-audio-api's `minSdkVersion`).

- Follow React Native: move the NDK when react-native-audio-api adopts an RN version whose
  template pins a new `ndkVersion`, not otherwise. Our libraries are plain C, so a different
  NDK in the app still links; matching keeps compiler and 16 KB page-size behaviour identical.
- Change `configs.json`, install that NDK, and run `yarn build:conan`. Conan profiles can't read
  JSON, so `conan/profiles/android.base` repeats `os.api_level` and `compiler.version` (the NDK's
  clang major), and each `android-<abi>` profile the API level in FFmpeg's `<triple><api>-clang`;
  `conan_build.sh` stops and names the file to change when they disagree.
- `conan.lock` doesn't depend on the NDK, so no relock. Release with a new tag; the CI cache key
  includes the NDK version, so it rebuilds from scratch.

### Releasing

1. Set `version` in `package.json` to the release (e.g. `5.0.0`) in a PR and merge it. That
   version is the release: the workflow only accepts the tag `v<version>` or a pre-release of
   it (`v5.0.0-rc.1`).
2. Run **Release** (`.github/workflows/release.yml`) from `main` (`workflow_dispatch`; leave the
   tag empty for `v<version>`, or enter an rc tag), or push a matching `v*` tag. It builds
   everything, runs `yarn verify --release`, attests build provenance for every asset and
   uploads them, with `checksums.txt`, to a **draft** release. It refuses a tag that doesn't
   match `package.json` or already has a release.
3. Point react-native-audio-api at the draft:

   ```bash
   gh release download <tag> -R software-mansion-labs/rn-audio-libs -p checksums.txt
   yarn bump:rn-audio-api <tag> checksums.txt ~/projects/react-native-audio-api
   ```

   It rewrites `TAG` in `packages/react-native-audio-api/scripts/download-prebuilt-binaries.sh`,
   `prebuiltBinariesTag` and the binary-target checksums in `Package.swift`. Open the PR there.
4. Draft assets can't be downloaded anonymously, so the downstream CI can't fetch them yet:
   publish the draft as a **pre-release** (`gh release edit <tag> --draft=false --prerelease`)
   and rerun the downstream PR's CI. The assets are now final; never change them.
5. Once the downstream PR is green, mark the release latest
   (`gh release edit <tag> --prerelease=false --latest`) and merge the PR. If it fails, fix
   forward with a new tag; the pre-release stays as a record.

To check an asset's provenance: `gh attestation verify <asset> -R software-mansion-labs/rn-audio-libs`.

### Rolling back

Revert the `TAG`/checksum bump commit in react-native-audio-api: the previous release stays
published and unchanged. Never delete or re-upload assets of a published tag; fix forward
with a new tag.

### OpenSSL security advisories

OpenSSL is linked statically into FFmpeg (the HTTPS/TLS protocols), so a fix reaches users only
through a new release here and a react-native-audio-api bump. We follow the 3.5 LTS line
(supported until April 2030).

1. Watch [openssl-library.org/news/vulnerabilities](https://openssl-library.org/news/vulnerabilities/)
   or the `openssl-announce` list. Advisories rated Low usually ship with the next release;
   Moderate and above: start once a fixed 3.5.x is out.
2. Wait for the 3.5.x recipe version on ConanCenter (usually within days; check
   `recipes/openssl/config.yml` in conan-center-index). If it lags, a local recipe export
   (`conan export <recipe> --version 3.5.x`) followed by `yarn lock:conan` works as a stopgap.
3. Bump `configs.json` `openssl.version`, `yarn lock:conan`, PR, release, downstream bump as
   above. Mention the CVE in the release notes.
4. Before 3.5 reaches end of life, move to the next LTS line the same way.
