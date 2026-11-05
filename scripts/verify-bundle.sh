#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
app="dist/Kambucha.app"
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
grep -qE '^Authority=(Apple Development|Developer ID Application): ' <<<"$info" || fail "signing authority"
team="$(sed -n 's/^TeamIdentifier=//p' <<<"$info")"
[[ "$team" =~ '^[A-Z0-9]{10}$' ]] || fail "no Team ID (unsigned, ad-hoc or team-less): $team"
grep -qE '^CodeDirectory .*flags=.*runtime' <<<"$info" || fail "hardened runtime is off"

# The requirements the agent pins (SignedCodeTrust), for the team that signed this build. Team ID is the
# certificate's OU, not the code in its name. Each must hold with the anchor, not just the claimed team.
pin="anchor apple generic and certificate leaf[subject.OU] = \"$team\""
codesign --verify --strict -R="identifier \"com.shaikjaleel.kambucha\" and $pin" "$app" || fail "app doesn't meet the caller requirement"
codesign --verify --strict -R="identifier \"com.shaikjaleel.kambucha.agent\" and $pin" "$app/Contents/MacOS/KambuchaAgent" || fail "agent can't prove its own team"
codesign --verify --strict -R="identifier \"com.shaikjaleel.kambucha.rclone\" and $pin" "$app/Contents/Helpers/rclone" || fail "rclone doesn't meet the helper requirement"

# rclone ships inside the app, so its MIT notice has to as well.
[[ -f "$app/Contents/Resources/Assets.car" && -f "$app/Contents/Resources/AppIcon.icns" ]] || fail "the app icon is missing"
grep -q 'Permission is hereby granted' "$app/Contents/Resources/ThirdPartyLicenses/rclone.txt" || fail "rclone's licence is missing"

# Keychain rule: only KambuchaAgent may touch it.
symbols="$(nm -u "$app/Contents/MacOS/Kambucha")" || fail "nm failed on Kambucha"
[[ -n "$symbols" ]] || fail "nm found no symbols in Kambucha"
if grep -qE '_SecItem|_SecKeychain' <<<"$symbols"; then fail "Kambucha references the Keychain"; fi

# Privileged binaries must not ship proof modes. Opt out only for a --proofs build.
if (( ! proofs )); then
  for b in KambuchaAgent Kambucha; do
    ! grep -aq -e '--probe' -e '--register-agent' -e '--snapshot' -e '--fixture' "$app/Contents/MacOS/$b" || fail "$b contains proof strings (a release build must not have them)"
  done
fi

out="$("$app/Contents/Helpers/rclone" version | head -1)"
[[ "$out" == "rclone v1.75.2" ]] || fail "rclone version: $out"
echo "OK"
