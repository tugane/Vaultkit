#!/bin/bash
#
# Render Vaultkit's app icon and pack it into an .icns.
#
#   scripts/make-icon.sh [out.icns]     # default: release/Vaultkit.icns
#
# The icon is generated from source rather than committed as a binary: it is a
# security tool, and "no opaque blob in the bundle you have to take on trust"
# is worth the one second this costs. The render is deterministic, so the same
# checkout always produces the same bytes.
#
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-release/Vaultkit.icns}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift Resources/AppIcon/MakeIcon.swift "$WORK/icon_1024.png" >/dev/null

mkdir -p "$WORK/Vaultkit.iconset"
# name:pixels. The full set iconutil expects; anything missing and it refuses.
for spec in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 \
            128x128@2x:256 256x256:256 256x256@2x:512 512x512:512 512x512@2x:1024; do
  name="${spec%%:*}"; px="${spec##*:}"
  sips -z "$px" "$px" "$WORK/icon_1024.png" \
       --out "$WORK/Vaultkit.iconset/icon_$name.png" >/dev/null
done

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$WORK/Vaultkit.iconset" -o "$OUT"
echo "icon: $OUT"
