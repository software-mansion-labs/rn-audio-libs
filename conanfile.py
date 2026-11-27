import json
import os

from conan import ConanFile

# The libraries rn-audio-libs builds with Conan. FFmpeg stays on scripts/ffmpeg_setup.sh, which
# links the OpenSSL built here.
LIBRARIES = ("ogg", "opus", "opusfile", "vorbis", "openssl")


class RnAudioLibsConan(ConanFile):
    name = "rn-audio-libs"
    settings = "os", "arch", "compiler", "build_type"
    default_options = {
        "*/*:shared": False,
        # The bash scripts configured opusfile with --disable-http; it needs no OpenSSL.
        "opusfile/*:http": False,
        # As the old `./Configure no-shared no-asm no-tests && make build_libs` (the recipe
        # always passes no-tests): only the libraries, no openssl command-line app.
        "openssl/*:no_asm": True,
        "openssl/*:no_apps": True,
        # OpenSSL's Configure leaves zlib out unless asked; the recipe defaults to requiring it.
        "openssl/*:no_zlib": True,
    }

    def requirements(self):
        with open(os.path.join(self.recipe_folder, "configs.json")) as configs:
            versions = json.load(configs)
        for library in LIBRARIES:
            self.requires(f"{library}/{versions[library]['version']}")
