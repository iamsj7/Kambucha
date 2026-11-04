#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
app="dist/Mirror.app"
proofs=0; [[ "${1:-}" == "--proofs" ]] && proofs=1
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

# Privileged binaries must not ship proof modes. Opt out only for a --proofs build.
if (( ! proofs )); then
  for b in MirrorAgent Mirror; do
    ! grep -aq -e '--probe' -e '--register-agent' "$app/Contents/MacOS/$b" || fail "$b contains proof strings (build with --proofs only for Gate 1)"
  done
fi

out="$("$app/Contents/Helpers/rclone" version | head -1)"
[[ "$out" == "rclone v1.75.2" ]] || fail "rclone version: $out"
echo "OK"
