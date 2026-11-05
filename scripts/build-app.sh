#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
IDENTITY="$(scripts/signing-identity.sh)"
[[ -x vendor/rclone/rclone && -f vendor/rclone/LICENSE.txt ]] || { echo "run scripts/fetch-rclone.sh first" >&2; exit 1; }

# Default build has no proof code. --proofs compiles the --probe* modes and --register-agent.
flags=()
[[ "${1:-}" == "--proofs" ]] && flags=(-Xswiftc -DKAMBUCHA_PROBES)
# KAMBUCHA_DIST / KAMBUCHA_SCRATCH let a proof run build somewhere other than dist/ and .build/.
scratch=(); [[ -n "${KAMBUCHA_SCRATCH:-}" ]] && scratch=(--scratch-path "$KAMBUCHA_SCRATCH")
swift build -c release --arch arm64 "${scratch[@]}" "${flags[@]}"
bin="$(swift build -c release --arch arm64 "${scratch[@]}" --show-bin-path)"
app="${KAMBUCHA_DIST:-${PWD}/dist}/Kambucha.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Library/LaunchAgents" "$app/Contents/Resources/ThirdPartyLicenses"
cp "$bin/Kambucha" "$app/Contents/MacOS/Kambucha"
cp "$bin/KambuchaAgent" "$app/Contents/MacOS/KambuchaAgent"
cp vendor/rclone/rclone "$app/Contents/Helpers/rclone"
cp vendor/rclone/LICENSE.txt "$app/Contents/Resources/ThirdPartyLicenses/rclone.txt"
# SwiftPM resource bundle (presets.json); Bundle.module finds it in Contents/Resources
cp -R "$bin/Kambucha_KambuchaCore.bundle" "$app/Contents/Resources/"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Icon Composer's document, compiled so macOS can apply its glass and appearances.
partial="$(mktemp)"
xcrun actool Resources/AppIcon.icon --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
  --app-icon AppIcon --output-partial-info-plist "$partial" --errors --warnings >/dev/null
rm -f "$partial"
cp Resources/com.shaikjaleel.kambucha.agent.plist "$app/Contents/Library/LaunchAgents/"

sign() { codesign --force --timestamp=none --options runtime --sign "$IDENTITY" "$@"; }
# The agent pins this identifier. It must differ from the app's: rclone can run commands, so it must
# never pass the agent's caller check.
sign --identifier com.shaikjaleel.kambucha.rclone "$app/Contents/Helpers/rclone"
sign --identifier com.shaikjaleel.kambucha.agent "$app/Contents/MacOS/KambuchaAgent"
sign "$app/Contents/MacOS/Kambucha"
sign "$app"
# The agent pins whichever team signed it and refuses everything without one, so this can't ship.
team="$(codesign -dvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$team" =~ '^[A-Z0-9]{10}$' ]] || { echo "the signature has no Team ID, so the agent would refuse to run: use an Apple Development or Developer ID Application identity" >&2; exit 1; }
echo "$app"
