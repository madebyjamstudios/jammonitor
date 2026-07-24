#!/bin/sh

set -eu

LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
OUTPUT="${SCRIPT_DIR}/vps-files.sha256"
TEMP=""

if command -v sha256sum >/dev/null 2>&1; then
    SHA256_TOOL="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    SHA256_TOOL="shasum"
else
    echo "sha256sum or shasum is required" >&2
    exit 1
fi

cleanup() {
    if [ -n "$TEMP" ]; then
        rm -f "$TEMP"
    fi
}
trap cleanup EXIT HUP INT TERM

TEMP="$(mktemp "${OUTPUT}.tmp.XXXXXX")"

(
    cd "$SCRIPT_DIR"
    for _file in \
        install-tailscale-watchdog.sh \
        jammonitor-tailscale-watchdog \
        jammonitor-tailscale-watchdog.service \
        jammonitor-tailscale-watchdog.timer \
        README.md
    do
        if [ "$SHA256_TOOL" = "sha256sum" ]; then
            sha256sum "$_file"
        else
            shasum -a 256 "$_file"
        fi
    done
) >"$TEMP"

chmod 0644 "$TEMP"
mv -f "$TEMP" "$OUTPUT"
trap - EXIT HUP INT TERM
