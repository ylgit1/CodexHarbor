#!/bin/zsh
# Regenerate every macOS icon size and the bundle ICNS from the committed
# 1024x1024 source. Both the Dock icon and the in-app brand use the same ICNS.
set -euo pipefail
project_root="${0:A:h:h}"
source_icon="$project_root/Resources/AppIcon-1024.png"
iconset="$project_root/Resources/AppIcon.iconset"
[[ -f "$source_icon" ]] || { echo "Missing icon source: $source_icon" >&2; exit 2; }
/usr/bin/sips -g pixelWidth -g pixelHeight "$source_icon" | grep -q 'pixelWidth: 1024' || exit 3
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
