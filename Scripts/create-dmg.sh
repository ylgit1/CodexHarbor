#!/bin/zsh
# Create a versioned compressed DMG from the signed application bundle.
set -euo pipefail
project_root="${0:A:h:h}"
app="$project_root/dist/Codex Harbor.app"
[[ -d "$app" ]] || { echo "Missing packaged app: $app" >&2; exit 2; }
/usr/bin/codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
arch="$(uname -m)"
dmg="$project_root/dist/Codex-Harbor-v${version}-${arch}.dmg"
stage="$(/usr/bin/mktemp -d "/tmp/codex-harbor-dmg.XXXXXX")"
/usr/bin/ditto "$app" "$stage/Codex Harbor.app"
/bin/ln -s /Applications "$stage/Applications"
/bin/cp "$app/Contents/Resources/AppIcon.icns" "$stage/.VolumeIcon.icns"
if /usr/bin/xcrun --find SetFile >/dev/null 2>&1; then
  /usr/bin/xcrun SetFile -a C "$stage" || true
fi
/usr/bin/hdiutil create -ov -format UDZO -imagekey zlib-level=9 \
  -volname "Codex Harbor" -srcfolder "$stage" "$dmg"
/usr/bin/hdiutil verify "$dmg"
/usr/bin/shasum -a 256 "$dmg"
/bin/ls -lh "$dmg"
