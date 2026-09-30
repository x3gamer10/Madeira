#!/bin/bash
# Build an update pack (docs/UPDATES.md): the Windows-side files that changed between
# the build installed on the device (its pe-manifest.txt) and this build.
#
#   scripts/make-update-pack.sh <installed build's pe-manifest.txt> [out.zip]
#
# Run after scripts/build-all-macos.sh (needs build-logs/pe-manifest.txt and
# build/ipa/Payload/Madeira.app). The zip holds madeira-updates/, which goes into
# "On My iPhone > Madeira" in the Files app. Only files that exist in this build are
# carried: a file removed since the installed build cannot be removed by a pack.
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_MANIFEST="${1:?usage: $0 <installed build pe-manifest.txt> [out.zip]}"
OUT="${2:-$R/build/ipa/madeira-update.zip}"
mkdir -p "$(dirname "$OUT")" && OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"  # zip runs in a temp dir
NEW_MANIFEST="$R/build-logs/pe-manifest.txt"
APP="$R/build/ipa/Payload/Madeira.app"

[ -f "$NEW_MANIFEST" ] && [ -d "$APP" ] || { echo "run scripts/build-all-macos.sh first" >&2; exit 1; }

base="$(shasum -a 256 "$BASE_MANIFEST" | cut -c1-64)"
new="$(shasum -a 256 "$NEW_MANIFEST" | cut -c1-64)"
if [ "$base" = "$new" ]; then
    echo "no Windows-side changes since build ${base:0:12}: no pack"
    exit 0
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
P="$STAGE/madeira-updates"
mkdir -p "$P"

# Manifest lines are "<sha256>  <path>" (shasum; the paths have no spaces; a binary-mode
# "*" before the path is ignored).
# macOS /bin/bash is 3.2 (no associative arrays), so the diff is awk's.
changed=0
while read -r kind p; do
    mkdir -p "$P/$(dirname "$p")"
    cp "$APP/$p" "$P/$p"
    echo "  $kind: $p"
    changed=$((changed + 1))
done < <(awk '{ sub(/^\*/, "", $2) }
              NR == FNR { old[$2] = $1; next }
              !($2 in old) { print "added", $2; next }
              old[$2] != $1 { print "changed", $2 }' "$BASE_MANIFEST" "$NEW_MANIFEST")

removed="$(awk '{ sub(/^\*/, "", $2) } NR == FNR { now[$2] = 1; next } !($2 in now) { print "  " $2 }' \
               "$NEW_MANIFEST" "$BASE_MANIFEST")"
[ -z "$removed" ] || { echo "WARNING: removed since the installed build (a pack cannot remove them):"; echo "$removed"; }

echo "$base" > "$P/base.txt"
cat > "$P/README.txt" <<EOF
Madeira update pack for build ${base:0:12} -> ${new:0:12} ($changed Windows-side files).

Install: in the Files app, open On My iPhone > Madeira, delete any old madeira-updates
folder, then put this madeira-updates folder there. Restart Madeira.
The log shows "[updates] pack active" when it is used, and "[updates] pack IGNORED" when
the installed Madeira is a different build. Delete the folder to go back to the app's
own files. A newer IPA ignores this pack.

Packs carry Windows-side files only (the DLL folders). Changes to Madeira's own code
still need a new IPA.
EOF
rm -f "$OUT"
(cd "$STAGE" && zip -qr "$OUT" madeira-updates)
echo "update pack: $OUT ($changed files, for build ${base:0:12})"
