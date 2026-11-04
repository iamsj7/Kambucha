#!/bin/zsh
# Gate 2: does an rclone copy into iCloud Drive share blocks (APFS clone) with its source?
# Uses a generated 256 MiB file in ~/Documents/.mirror-proof-tmp, never a real project.
# Deletes only the two folders it creates.
set -euo pipefail
cd "${0:A:h}/.."
RCLONE="${RCLONE:-$PWD/dist/Mirror.app/Contents/Helpers/rclone}"
SRC="$HOME/Documents/.mirror-proof-tmp"
PLAIN="$(mktemp -d "$HOME/Documents/.mirror-proof-plain.XXXXXX")"
DEST="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Mac Backup Test"
[[ -e "$DEST" ]] && { echo "refusing: $DEST already exists" >&2; exit 1; }
[[ -e "$SRC" ]] && { echo "refusing: $SRC already exists" >&2; exit 1; }
used() { sync; sleep 3; df -k /System/Volumes/Data | awk 'NR==2{print $3}'; }
cleanup() { rm -rf "$SRC" "$PLAIN" "$DEST"; }
trap cleanup EXIT

mkdir -p "$SRC"
dd if=/dev/urandom of="$SRC/blob.bin" bs=1048576 count=256 2>/dev/null
A=$(used)
cat "$SRC/blob.bin" > "$PLAIN/blob.bin"
B=$(used)
"$RCLONE" copy "$SRC" "$DEST"
C=$(used)
plain=$((B - A)); clone=$((C - B))
echo "df used KiB: after-generate=$A after-plain-cat=$B after-rclone-copy=$C"
echo "plain cat delta KiB=$plain  rclone clone delta KiB=$clone"
pct=$(awk -v c=$clone -v p=$plain 'BEGIN{printf "%.2f", 100*c/p}')
echo "clone uses ${pct}% of plain copy"
cmp "$SRC/blob.bin" "$DEST/blob.bin" && echo "content identical"
awk -v p=$pct 'BEGIN{exit !(p<5)}' && echo "GATE 2: PASS (<5%)" || echo "GATE 2: FAIL (>=5%)"
