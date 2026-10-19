#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
OUTPUTS_DIR="$ROOT_DIR/outputs"
EXPORT_DIR="$ROOT_DIR/export"

if [ ! -d "$OUTPUTS_DIR" ]; then
    echo "Error: outputs directory not found at $OUTPUTS_DIR"
    exit 1
fi

mkdir -p "$EXPORT_DIR"
rm -f "$EXPORT_DIR"/*.zip

if ! command -v zip >/dev/null 2>&1; then
    echo "Error: zip command is required"
    exit 1
fi

shopt -s nullglob
packed_any=false

for dir in "$OUTPUTS_DIR"/*; do
    [ -d "$dir" ] || continue

    name="$(basename "$dir")"

    # The Ogg/Opus/Vorbis headers stay tracked in react-native-audio-api. The FFmpeg
    # headers are not: download-prebuilt-binaries.sh fetches include_ffmpeg.zip there
    # whenever FFmpeg is enabled, so it has to ship as a release asset.
    if [[ "$name" == "include" ]]; then
        continue
    fi

    packed_any=true
    archive_path="$EXPORT_DIR/${name}.zip"

    rm -f "$archive_path"
    (
        cd "$OUTPUTS_DIR"
        zip -qry "$archive_path" "$name"
    )

    echo "Packed $name -> $archive_path"
done

if [ "$packed_any" = false ]; then
    echo "No directories found in $OUTPUTS_DIR"
fi
