#!/bin/zsh
# Gate 2 (deterministic): do copies into iCloud Drive share physical blocks with their source?
# Reads physical offsets via F_LOG2PHYS_EXT (MirrorAgent --probe-blocks) instead of df.
# Generated data only. Deletes only ~/Documents/.mirror-proof-tmp and "Mac Backup Test" in iCloud Drive.
set -euo pipefail
cd "${0:A:h}/.."
RCLONE="${RCLONE:-$PWD/dist/Mirror.app/Contents/Helpers/rclone}"
AGENT="$PWD/dist/Mirror.app/Contents/MacOS/MirrorAgent"
SRC="$HOME/Documents/.mirror-proof-tmp"
BASE="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Mac Backup Test"
[[ -e "$BASE" ]] && { echo "refusing: $BASE exists" >&2; exit 1; }
[[ -e "$SRC" ]] && { echo "refusing: $SRC exists" >&2; exit 1; }
trap 'rm -rf "$SRC" "$BASE"' EXIT
mkdir -p "$SRC/src/sub"
dd if=/dev/urandom of="$SRC/src/big1.bin" bs=1048576 count=64 2>/dev/null
dd if=/dev/urandom of="$SRC/src/sub/big2.bin" bs=1048576 count=64 2>/dev/null
echo small > "$SRC/src/small.txt"
ln -s big1.bin "$SRC/src/link-to-file"; ln -s sub "$SRC/src/link-to-dir"; ln -s nowhere "$SRC/src/broken"
S="$SRC/src"

same() {  # src file, dest file -> SHARED / NOT SHARED
  local a b; a=$("$AGENT" --probe-blocks "$1"); b=$("$AGENT" --probe-blocks "$2")
  echo "   src : $a"; echo "   dest: $b"
  [[ "$a" == "$b" ]] && echo "   => SHARED" || echo "   => NOT SHARED"
}

echo "##### detector control (tmp, same volume)"
cp -c "$S/big1.bin" "$SRC/ctl-clone"; cp "$S/big1.bin" "$SRC/ctl-plain"
echo " cp -c:"; same "$S/big1.bin" "$SRC/ctl-clone"
echo " cp (plain):"; same "$S/big1.bin" "$SRC/ctl-plain"
rm "$SRC/ctl-clone" "$SRC/ctl-plain"

run() {  # name, rclone-src, rclone-dest, dest path
  local n="$1"
  echo; echo "##### $n"
  "$RCLONE" copy $2 "$3" -v 2>&1 | grep -E "Copied|ERROR|Failed" | sed 's/^[0-9/]* [0-9:]* //'
  echo " dest files:"; (cd "$4" && find . | sort | sed 's/^/   /')
  echo " before upload, big1.bin:"; same "$S/big1.bin" "$4/big1.bin"
  echo " before upload, sub/big2.bin:"; same "$S/sub/big2.bin" "$4/sub/big2.bin"
  echo " wait for upload"; "$AGENT" --probe-uploaded "$4" 480 | tail -1
  echo " after upload, big1.bin:"; same "$S/big1.bin" "$4/big1.bin"
  echo " after upload, sub/big2.bin:"; same "$S/sub/big2.bin" "$4/sub/big2.bin"
  echo " ubiquity keys on every entry (not following symlinks):"
  (cd "$4" && find . -mindepth 1 | sort | while read -r f; do "$AGENT" --probe-ubiq "$4/$f"; done) | sed "s|$BASE/||; s/^/   /"
}
run N-no-links "$S" "$BASE/N" "$BASE/N"
run A-links-both ":local,links:$S" ":local,links:$BASE/A" "$BASE/A"
run B-links-source-only ":local,links:$S" "$BASE/B" "$BASE/B"
