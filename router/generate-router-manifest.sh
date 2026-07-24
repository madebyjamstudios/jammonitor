#!/bin/sh
#
# Generate the deterministic checksum manifest consumed by
# install-jammonitor-router.sh. Run this after every payload change and again
# immediately before the release commit is created.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
OUTPUT="${1:-$SCRIPT_DIR/router-files.sha256}"
OUTPUT_DIR="$(dirname -- "$OUTPUT")"

FILES='
jammonitor.lua
jammonitor.htm
jammonitor.js
jammonitor-i18n.js
router/jammonitor-collect
router/jammonitor-history.init
router/jammonitor-tailscale-watchdog
router/jammonitor-tailscale-watchdog.init
router/tailscale.init
router/upgrade-tailscale-arm64.sh
router/install-jammonitor-router.sh
'

if command -v sha256sum >/dev/null 2>&1; then
    SHA256_TOOL="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    SHA256_TOOL="shasum"
else
    printf 'sha256sum or shasum is required\n' >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
TMP_FILE="$(mktemp "$OUTPUT_DIR/.router-files.sha256.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT HUP INT TERM

(
    cd "$REPO_ROOT"
    LC_ALL=C
    export LC_ALL
    for file in $FILES; do
        if [ ! -f "$file" ]; then
            printf 'Missing manifest payload: %s\n' "$file" >&2
            exit 1
        fi
        if [ "$SHA256_TOOL" = "sha256sum" ]; then
            sha256sum "$file"
        else
            shasum -a 256 "$file"
        fi
    done
) > "$TMP_FILE"

chmod 0644 "$TMP_FILE"
mv -f "$TMP_FILE" "$OUTPUT"
trap - EXIT HUP INT TERM
printf 'Wrote %s\n' "$OUTPUT"
