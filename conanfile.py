import json
import os

from conan import ConanFile

# Every library rn-audio-libs ships, at the versions in configs.json.
# zlib is linked into FFmpeg; requiring it here pins its version and has Conan deploy its license.
LIBRARIES = ("ogg", "opus", "opusfile", "vorbis", "openssl", "zlib", "ffmpeg")

# What FFmpeg is built with: decoding and encoding of the formats react-native-audio-api reads
# and writes, and streaming over HTTP(S) with the OpenSSL built here.
FFMPEG_COMPONENTS = {
    "enable_decoders": "aac,mp3,flac,alac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f32be,pcm_s16be",
    "enable_encoders": "aac,mp3,flac,pcm_s16le",
    "enable_demuxers": "hls,mov,mp3,flac,caf",
    "enable_muxers": "wav,mp4,flac,caf",
    "enable_parsers": "aac",
    "enable_protocols": "https,tls,tcp,http,udp,file",
}

# The recipe turns these on by default; FFmpeg here uses none of them.
FFMPEG_DISABLED = (
    "avdevice", "swscale", "postproc", "avfilter", "with_programs",
    "with_bzip2", "with_lzma", "with_libiconv", "with_freetype", "with_openjpeg",
    "with_openh264", "with_opus", "with_vorbis", "with_libx264", "with_libx265", "with_libvpx",
    "with_libmp3lame", "with_libfdk_aac", "with_libwebp", "with_libsvtav1", "with_libaom",
    "with_libdav1d", "with_libalsa", "with_pulse", "with_vaapi", "with_vdpau", "with_xcb",
    "with_xlib", "with_appkit", "with_avfoundation", "with_coreimage", "with_audiotoolbox",
    "with_videotoolbox", "with_mediacodec", "with_jni",
)


class RnAudioLibsConan(ConanFile):
    name = "rn-audio-libs"
    settings = "os", "arch", "compiler", "build_type"
    default_options = {
        # Static, except FFmpeg, which ships as dylibs/.so with OpenSSL and zlib linked in.
        "*/*:shared": False,
        "ffmpeg/*:shared": True,
        # The bash scripts configured opusfile with --disable-http; it needs no OpenSSL.
        "opusfile/*:http": False,
        # As the old `./Configure no-shared no-asm no-tests && make build_libs` (the recipe
        # always passes no-tests): only the libraries, no openssl command-line app.
        "openssl/*:no_asm": True,
        "openssl/*:no_apps": True,
        # OpenSSL's Configure leaves zlib out unless asked; the recipe defaults to requiring it.
        "openssl/*:no_zlib": True,
        "ffmpeg/*:disable_everything": True,
        **{f"ffmpeg/*:{option}": value for option, value in FFMPEG_COMPONENTS.items()},
        **{f"ffmpeg/*:{option}": False for option in FFMPEG_DISABLED},
        "ffmpeg/*:with_ssl": "openssl",
        # gzip HTTP responses, compressed MOV headers and compressed ID3 frames, on every platform.
        "ffmpeg/*:with_zlib": True,
        # Keeps ARM NEON assembly; the profiles add --disable-x86asm --disable-inline-asm, as the
        # bash build did (the recipe's with_asm=False would pass --disable-asm, dropping NEON too).
        "ffmpeg/*:with_asm": True,
    }

    def requirements(self):
        with open(os.path.join(self.recipe_folder, "configs.json")) as configs:
            versions = json.load(configs)
        for library in LIBRARIES:
            self.requires(f"{library}/{versions[library]['version']}")
