#!/bin/zsh
# Prints the identity to sign with: MIRROR_SIGN_IDENTITY, or else the only Apple signing identity
# installed. A hash when picked here, as two certificates can share a name.
set -euo pipefail
if [[ -n "${MIRROR_SIGN_IDENTITY:-}" ]]; then
  if [[ "$MIRROR_SIGN_IDENTITY" == "-" ]]; then
    echo "MIRROR_SIGN_IDENTITY can't be ad-hoc: the agent refuses a build with no Team ID" >&2
    exit 1
  fi
  print -r -- "$MIRROR_SIGN_IDENTITY"
  exit 0
fi
found=("${(@f)$(security find-identity -v -p codesigning | sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) "((Apple Development|Developer ID Application): .*)"$/\1 \2/p')}")
found=(${found:#})
if (( ${#found} == 0 )); then
  echo 'No "Apple Development" or "Developer ID Application" identity found. Add one in Xcode (Settings > Accounts), or set MIRROR_SIGN_IDENTITY.' >&2
  exit 1
fi
if (( ${#found} > 1 )); then
  echo "Several signing identities found. Set MIRROR_SIGN_IDENTITY to the one to use:" >&2
  printf '  %s\n' "${found[@]}" >&2
  exit 1
fi
print -r -- "${found[1]%% *}"
