#!/usr/bin/env python3
"""Points a react-native-audio-api checkout at a new rn-audio-libs release.

Rewrites the release tag in packages/react-native-audio-api/scripts/download-prebuilt-binaries.sh
and in Package.swift, and every SwiftPM binary-target checksum in Package.swift, from the
release's checksums.txt ("<name> <sha256>" per line, written by pack_spm_xcframeworks.sh).

Usage: scripts/bump_rn_audio_api.py <tag> <checksums.txt> <react-native-audio-api checkout>
   or: yarn bump:rn-audio-api <tag> <checksums.txt> <react-native-audio-api checkout>
"""
import os
import re
import sys
from pathlib import Path

PACKAGE = Path("packages/react-native-audio-api")


def user_path(argument):
    # yarn runs the script from the repo root; INIT_CWD is where the command was typed.
    return Path(os.environ.get("INIT_CWD", os.getcwd())) / Path(argument).expanduser()


def substitute(text, pattern, replacement, what):
    new_text, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if count != 1:
        sys.exit(f"Error: expected one {what}, found {count}")
    return new_text


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    tag, checksums_path, checkout = sys.argv[1], user_path(sys.argv[2]), user_path(sys.argv[3])
    if not re.fullmatch(r"v\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?", tag):
        sys.exit(f"Error: {tag!r} is not a vX.Y.Z tag")

    checksums = {}
    for line in checksums_path.read_text().splitlines():
        if line.strip():
            name, checksum = line.split()
            if not re.fullmatch(r"[0-9a-f]{64}", checksum):
                sys.exit(f"Error: bad checksum for {name}: {checksum}")
            checksums[name] = checksum

    download_script = checkout / PACKAGE / "scripts/download-prebuilt-binaries.sh"
    download_text = substitute(download_script.read_text(), r'^TAG="[^"]*"$', f'TAG="{tag}"',
                               "TAG= line")

    package_swift = checkout / PACKAGE / "Package.swift"
    text = package_swift.read_text()
    text = substitute(text, r'^let prebuiltBinariesTag = "[^"]*"$',
                      f'let prebuiltBinariesTag = "{tag}"', "prebuiltBinariesTag")
    pinned = re.findall(r'^\s*"([A-Za-z0-9_]+)": "[0-9a-f]{64}",?$', text, flags=re.MULTILINE)
    if set(pinned) != set(checksums):
        sys.exit(f"Error: Package.swift pins {sorted(pinned)}, checksums.txt has {sorted(checksums)}")
    for name, checksum in checksums.items():
        text = substitute(text, rf'^(\s*"{name}": )"[0-9a-f]{{64}}"', rf'\g<1>"{checksum}"',
                          f"{name} checksum")

    # Write only once both files are known to be rewritable.
    download_script.write_text(download_text)
    package_swift.write_text(text)

    print(f"Pointed {checkout} at rn-audio-libs {tag} ({len(checksums)} checksums)")


if __name__ == "__main__":
    main()
