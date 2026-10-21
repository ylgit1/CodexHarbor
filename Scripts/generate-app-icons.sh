#!/bin/zsh
# Regenerate a correctly alpha-masked, inset macOS icon from pristine artwork,
# then produce every iconset size and the bundle ICNS. The Dock, Launchpad and
# in-app brand all use the same ICNS.
set -euo pipefail
project_root="${0:A:h:h}"
source_artwork="$project_root/Resources/AppIconArtwork-1024.png"
source_icon="$project_root/Resources/AppIcon-1024.png"
iconset="$project_root/Resources/AppIcon.iconset"
[[ -f "$source_artwork" ]] || { echo "Missing original artwork: $source_artwork" >&2; exit 2; }
/usr/bin/sips -g pixelWidth -g pixelHeight "$source_artwork" | grep -q 'pixelWidth: 1024' || exit 3
/usr/bin/swift "$project_root/Scripts/make-rounded-app-icon.swift" "$source_artwork" "$source_icon"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  /usr/bin/sips -s format png --resampleHeightWidth "$size" "$size" "$source_icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  if [[ "$size" != "512" ]]; then
    double=$((size * 2))
    /usr/bin/sips -s format png --resampleHeightWidth "$double" "$double" "$source_icon" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  else
    cp "$source_icon" "$iconset/icon_512x512@2x.png"
  fi
done
/usr/bin/iconutil -c icns "$iconset" -o "$project_root/Resources/AppIcon.icns"
echo "Updated AppIcon-1024.png, all 10 iconset files and AppIcon.icns"
