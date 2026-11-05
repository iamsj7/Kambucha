#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
IDENTITY="$(scripts/signing-identity.sh)"
[[ -x vendor/rclone/rclone ]] || { echo "run scripts/fetch-rclone.sh first" >&2; exit 1; }

# Default build has no proof code. --proofs compiles the --probe* modes and --register-agent (Gate 1 only).
flags=()
[[ "${1:-}" == "--proofs" ]] && flags=(-Xswiftc -DMIRROR_PROBES)
# MIRROR_DIST / MIRROR_SCRATCH let a proof run build somewhere other than dist/ and .build/.
scratch=(); [[ -n "${MIRROR_SCRATCH:-}" ]] && scratch=(--scratch-path "$MIRROR_SCRATCH")
swift build -c release --arch arm64 "${scratch[@]}" "${flags[@]}"
bin="$(swift build -c release --arch arm64 "${scratch[@]}" --show-bin-path)"
app="${MIRROR_DIST:-${PWD}/dist}/Mirror.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Library/LaunchAgents" "$app/Contents/Resources"
cp "$bin/Mirror" "$app/Contents/MacOS/Mirror"
cp "$bin/MirrorAgent" "$app/Contents/MacOS/MirrorAgent"
cp vendor/rclone/rclone "$app/Contents/Helpers/rclone"
# SwiftPM resource bundle (presets.json); Bundle.module finds it in Contents/Resources
cp -R "$bin/Mirror_MirrorCore.bundle" "$app/Contents/Resources/"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/com.shaikjaleel.mirror.agent.plist "$app/Contents/Library/LaunchAgents/"

sign() { codesign --force --timestamp=none --options runtime --sign "$IDENTITY" "$@"; }
# The agent pins this identifier. It must differ from the app's: rclone can run commands, so it must
# never pass the agent's caller check.
sign --identifier com.shaikjaleel.mirror.rclone "$app/Contents/Helpers/rclone"
sign --identifier com.shaikjaleel.mirror.agent "$app/Contents/MacOS/MirrorAgent"
sign "$app/Contents/MacOS/Mirror"
sign "$app"
# The agent pins whichever team signed it and refuses everything without one, so this can't ship.
team="$(codesign -dvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$team" =~ '^[A-Z0-9]{10}$' ]] || { echo "the signature has no Team ID, so the agent would refuse to run: use an Apple Development or Developer ID Application identity" >&2; exit 1; }
echo "$app"
