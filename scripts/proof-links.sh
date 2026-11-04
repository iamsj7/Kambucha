#!/bin/zsh
# Gate 3: symlink round trip through iCloud Drive with rclone --links.
# Creates and deletes only: a temp source, a temp restore folder, and "Mac Backup Test/links".
set -euo pipefail
cd "${0:A:h}/.."
RCLONE="${RCLONE:-$PWD/dist/Mirror.app/Contents/Helpers/rclone}"
AGENT="$PWD/dist/Mirror.app/Contents/MacOS/MirrorAgent"
WORK="$(mktemp -d)"
SRC="$WORK/src"
BASE="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Mac Backup Test"
[[ -e "$BASE" ]] && { echo "refusing: $BASE already exists" >&2; exit 1; }
cleanup() { rm -rf "$WORK" "$BASE"; }
trap cleanup EXIT

mkdir -p "$SRC/dir/inner"
echo hello > "$SRC/file.txt"
echo deep > "$SRC/dir/inner/deep.txt"
ln -s file.txt "$SRC/link-to-file"            # relative, to file
ln -s dir "$SRC/link-to-dir"                  # relative, to directory
ln -s inner/deep.txt "$SRC/dir/rel-link"      # relative, nested
ln -s "$SRC/file.txt" "$SRC/abs-link"         # absolute
ln -s does-not-exist "$SRC/broken-link"       # broken
ln -s ../file.txt "$SRC/dir/up-link"          # relative, parent


# Variant A: --links on both sides. The destination (a local path in iCloud Drive) gets real symlinks.
# Variant B: links only on the source side. iCloud Drive stores plain ".rclonelink" files.
# The engine will use B (links stay as files in the mirror), so B is the gate; A is recorded for information.
phase() {  # name, srcspec, destspec, dest path, restore-source, restore-dest
  local name="$1" srcspec="$2" destspec="$3" dest="$4" restoresrc="$5" restoredest="$6" out="$WORK/restored-$1"
  mkdir -p "$out"
  echo; echo "######## variant $name"
  echo "== sync"
  "$RCLONE" sync $srcspec "$destspec" -v 2>&1 | grep -E "Copied|ERROR|Failed" || true
  echo "== remote listing"; find "$dest" | sort | sed "s|$BASE/||"
  echo "== wait for upload"
  "$AGENT" --probe-uploaded "$dest" 480
  echo "== check --links --size-only"
  "$RCLONE" check --size-only $srcspec "$destspec" 2>&1 | grep -v "Config file" || true
  echo "== restore"
  "$RCLONE" copy "$restoresrc" "${restoredest/OUT/$out}" 2>&1 | grep -v "Config file" || true
  echo "== compare"
  ( cd "$SRC" && find . -type l | sort | while read l; do echo "$l -> $(readlink "$l")"; done ) > "$WORK/a-$name.txt"
  ( cd "$out" && find . -type l | sort | while read l; do echo "$l -> $(readlink "$l")"; done ) > "$WORK/b-$name.txt"
  cat "$WORK/b-$name.txt"
  if diff "$WORK/a-$name.txt" "$WORK/b-$name.txt" && diff <(cd "$SRC"; find . -type f | sort) <(cd "$out"; find . -type f | sort); then
    echo "variant $name: PASS (symlinks and files identical)"
  else
    echo "variant $name: FAIL"; return 1
  fi
}
rc=0
phase A ":local,links:$SRC" ":local,links:$BASE/A-links" "$BASE/A-links" ":local,links:$BASE/A-links" ":local,links:OUT" || rc=1
phase B ":local,links:$SRC" "$BASE/B-rclonelink" "$BASE/B-rclonelink" "$BASE/B-rclonelink" ":local,links:OUT" || rc=1
echo; [[ $rc == 0 ]] && echo "GATE 3: PASS" || echo "GATE 3: FAIL"
exit $rc
