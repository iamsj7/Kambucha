#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
app="dist/Mirror.app"
fail() { echo "FAIL: $*" >&2; exit 1; }

codesign --verify --deep --strict "$app" || fail "codesign verify"

while IFS= read -r f; do
  if file "$f" | grep -q 'Mach-O'; then
    archs="$(lipo -archs "$f")"
    [[ "$archs" == "arm64" ]] || fail "$f archs: $archs"
  fi
done < <(find "$app/Contents" -type f)

info="$(codesign -dvv "$app" 2>&1)"
grep -q '^Authority=Apple Development: Shaik Jaleel' <<<"$info" || fail "signing authority"

out="$("$app/Contents/Helpers/rclone" version | head -1)"
[[ "$out" == "rclone v1.75.2" ]] || fail "rclone version: $out"
echo "OK"
