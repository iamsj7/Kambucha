#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
IDENTITY="${MIRROR_SIGN_IDENTITY:-Apple Development: Shaik Jaleel}"
[[ -x vendor/rclone/rclone ]] || { echo "run scripts/fetch-rclone.sh first" >&2; exit 1; }

# Default build has no proof code. --proofs compiles the --probe* modes and --register-agent (Gate 1 only).
flags=()
[[ "${1:-}" == "--proofs" ]] && flags=(-Xswiftc -DMIRROR_PROBES)
swift build -c release --arch arm64 "${flags[@]}"
bin="$(swift build -c release --arch arm64 --show-bin-path)"
app="${PWD}/dist/Mirror.app"
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
sign "$app/Contents/Helpers/rclone"
sign --identifier com.shaikjaleel.mirror.agent "$app/Contents/MacOS/MirrorAgent"
sign "$app/Contents/MacOS/Mirror"
sign "$app"
echo "$app"
