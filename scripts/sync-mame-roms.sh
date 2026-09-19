#!/usr/bin/env bash
# Scan a folder of .mra files, collect the MAME zip filenames referenced by
# their zip="..." attributes (pipe-separated lists included), and upload
# those zips from a local MAME ROMs folder to a MiSTer over SFTP.
#
# Usage: sync-mame-roms.sh [mra_dir] [rom_src] [sftp_host] [sftp_user] [sftp_pass]
set -euo pipefail

MRA_DIR="${1:-.}"
ROM_SRC="${2:-F:/Emulation/roms/MAME 0.286 ROMs (merged)}"
SFTP_HOST="${3:-192.168.68.251}"
SFTP_USER="${4:-root}"
SFTP_PASS="${5:-1}"

REMOTE_DIR="/media/fat/games/mame"

if [[ ! -d "$MRA_DIR" ]]; then
    echo "Error: .mra folder not found: $MRA_DIR" >&2
    exit 1
fi

if [[ ! -d "$ROM_SRC" ]]; then
    echo "Error: ROM source folder not found: $ROM_SRC" >&2
    exit 1
fi

shopt -s nullglob
mra_files=("$MRA_DIR"/*.mra "$MRA_DIR"/*.MRA)
shopt -u nullglob

if [[ ${#mra_files[@]} -eq 0 ]]; then
    echo "No .mra files found in $MRA_DIR" >&2
    exit 1
fi

# Pull every zip="..." value, split on '|', dedupe.
mapfile -t zip_files < <(
    grep -hoE 'zip="[^"]*"' "${mra_files[@]}" \
        | sed -E 's/zip="([^"]*)"/\1/' \
        | tr '|' '\n' \
        | sed '/^$/d' \
        | sort -u
)

if [[ ${#zip_files[@]} -eq 0 ]]; then
    echo "No zip= attributes found in $MRA_DIR" >&2
    exit 1
fi

echo "Found ${#zip_files[@]} unique zip file(s) referenced across ${#mra_files[@]} .mra file(s)."

missing=()
to_upload=()
for zip in "${zip_files[@]}"; do
    local_path="$ROM_SRC/$zip"
    if [[ -f "$local_path" ]]; then
        to_upload+=("$zip")
    else
        missing+=("$zip")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Warning: ${#missing[@]} zip file(s) not found in '$ROM_SRC' and will be skipped:" >&2
    printf '  %s\n' "${missing[@]}" >&2
fi

if [[ ${#to_upload[@]} -eq 0 ]]; then
    echo "Nothing to upload." >&2
    exit 1
fi

echo "Uploading ${#to_upload[@]} zip file(s) to $SFTP_USER@$SFTP_HOST:$REMOTE_DIR ..."

for zip in "${to_upload[@]}"; do
    echo "  -> $zip"
    curl -sS --insecure -u "$SFTP_USER:$SFTP_PASS" \
        -T "$ROM_SRC/$zip" \
        "sftp://$SFTP_HOST$REMOTE_DIR/$zip"
done

echo "Done."
