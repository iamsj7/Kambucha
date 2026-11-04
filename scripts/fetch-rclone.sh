#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
VERSION="v1.75.2"
SHA256="610ab7d48615135dfc60b763858b11a426a0d3d1160c1bb76fb0ae6011b02edd"
URL="https://downloads.rclone.org/${VERSION}/rclone-${VERSION}-osx-arm64.zip"
dir="vendor/rclone"
zip="$dir/rclone-${VERSION}-osx-arm64.zip"
mkdir -p "$dir"
if [[ ! -f "$zip" ]] || [[ "$(shasum -a 256 "$zip" | awk '{print $1}')" != "$SHA256" ]]; then
  curl -fsSL -o "$zip" "$URL"
fi
actual="$(shasum -a 256 "$zip" | awk '{print $1}')"
if [[ "$actual" != "$SHA256" ]]; then
  echo "SHA-256 mismatch for $zip: expected $SHA256, got $actual" >&2
  rm -f "$zip"
  exit 1
fi
rm -rf "$dir/extracted"
mkdir -p "$dir/extracted"
unzip -q -o "$zip" -d "$dir/extracted"
cp "$dir/extracted/rclone-${VERSION}-osx-arm64/rclone" "$dir/rclone"
chmod +x "$dir/rclone"
echo "$dir/rclone"
