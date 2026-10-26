#!/bin/zsh
# Create a versioned compressed DMG from the signed application bundle.
set -euo pipefail
project_root="${0:A:h:h}"
app="$project_root/dist/Codex Harbor.app"
[[ -d "$app" ]] || { echo "Missing packaged app: $app" >&2; exit 2; }
/usr/bin/codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
commit="$(/usr/libexec/PlistBuddy -c 'Print :HarborGitCommit' "$app/Contents/Info.plist")"
arch="$(uname -m)"
tag="$(git -C "$project_root" describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null || true)"
head_commit="$(git -C "$project_root" rev-parse --short=12 HEAD 2>/dev/null || true)"
if [[ "$tag" == "v$version" && "$commit" == "$head_commit" \
  && -z "$(git -C "$project_root" status --porcelain)" ]]; then
  label="v$version"
else
  label="dev-$commit"
fi
dmg="$project_root/dist/Codex-Harbor-${label}-${arch}.dmg"
if [[ "${1:-}" == "--print-path" ]]; then
  print -r -- "$dmg"
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo "用法：$0 [--print-path]" >&2
  exit 2
fi
stage="$(/usr/bin/mktemp -d "/tmp/codex-harbor-dmg.XXXXXX")"
trap '/bin/rm -rf -- "$stage"' EXIT
/usr/bin/ditto "$app" "$stage/Codex Harbor.app"
/bin/ln -s /Applications "$stage/Applications"
/bin/cp "$app/Contents/Resources/AppIcon.icns" "$stage/.VolumeIcon.icns"
if /usr/bin/xcrun --find SetFile >/dev/null 2>&1; then
  /usr/bin/xcrun SetFile -a C "$stage" || true
fi
/usr/bin/hdiutil create -ov -format UDZO -imagekey zlib-level=9 \
  -volname "Codex Harbor" -srcfolder "$stage" "$dmg"
/usr/bin/hdiutil verify "$dmg"
LC_ALL=C /usr/bin/shasum -a 256 "$dmg"
/bin/ls -lh "$dmg"
