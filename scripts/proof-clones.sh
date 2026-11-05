#!/bin/zsh
# Do copies into iCloud Drive share physical blocks with their source?
# Reads physical offsets via F_LOG2PHYS_EXT (KambuchaAgent --probe-blocks) instead of df.
# Generated data only. Deletes only ~/Documents/.kambucha-proof-tmp and "Mac Backup Test" in iCloud Drive.
set -euo pipefail
cd "${0:A:h}/.."
# Bundle under test (a --proofs build). Override only with KAMBUCHA_APP, never the tool paths.
APP="${KAMBUCHA_APP:-$PWD/dist/Kambucha.app}"
RCLONE="$APP/Contents/Helpers/rclone"
AGENT="$APP/Contents/MacOS/KambuchaAgent"
[[ -x "$RCLONE" && -x "$AGENT" ]] || { echo "not a bundle: $APP" >&2; exit 1; }
SRC="$HOME/Documents/.kambucha-proof-tmp"
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

same() {  # src file, dest file -> SHARED / NOT SHARED; aborts the proof if offsets cannot be read
  local a b
  a=$("$AGENT" --probe-blocks "$1") || { echo "PROOF ERROR: cannot read blocks of $1: $a" >&2; exit 2; }
  b=$("$AGENT" --probe-blocks "$2") || { echo "PROOF ERROR: cannot read blocks of $2: $b" >&2; exit 2; }
  for v in "$a" "$b"; do
    [[ "$v" == *err* || ! "$v" =~ '[0-9]+:[0-9]+' ]] && { echo "PROOF ERROR: no valid offsets: $v" >&2; exit 2; }
  done
  echo "   src : $a (sampled every 16 MiB)"; echo "   dest: $b"
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
