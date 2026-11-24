#!/bin/zsh
# Create a versioned compressed DMG from the signed application bundle.
set -euo pipefail
project_root="${0:A:h:h}"
app="$project_root/dist/Codex Harbor.app"
[[ -d "$app" ]] || { echo "Missing packaged app: $app" >&2; exit 2; }
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
/usr/bin/codesign --verify --deep --strict "$app"
stage="$(/usr/bin/mktemp -d "/tmp/codex-harbor-dmg.XXXXXX")"
output_stage=""
trap '/bin/rm -rf -- "$stage"; if [[ -n "$output_stage" ]]; then /bin/rm -rf -- "$output_stage"; fi' EXIT
output_stage="$(/usr/bin/mktemp -d "$project_root/dist/.dmg-build.XXXXXX")"
pending_dmg="$output_stage/installer.dmg"
/usr/bin/ditto "$app" "$stage/Codex Harbor.app"
/bin/ln -s /Applications "$stage/Applications"
/bin/cp "$app/Contents/Resources/AppIcon.icns" "$stage/.VolumeIcon.icns"
if /usr/bin/xcrun --find SetFile >/dev/null 2>&1; then
  /usr/bin/xcrun SetFile -a C "$stage" || true
fi
# Retrying a transient disk image error must not repeat the Swift build.
# Keep the previous verified installer until its replacement is verified.
compression="${CODEX_HARBOR_DMG_COMPRESSION:-6}"
[[ "$compression" == [1-9] ]] || { echo "Invalid DMG compression level" >&2; exit 2; }
for attempt in 1 2 3; do
  if /usr/bin/hdiutil create -ov -format UDZO -imagekey "zlib-level=$compression" \
      -volname "Codex Harbor" -srcfolder "$stage" "$pending_dmg" >"$output_stage/create.log" 2>&1; then
    /bin/cat "$output_stage/create.log"
    break
  fi
  /bin/cat "$output_stage/create.log" >&2
  if [[ "$attempt" == 3 ]] || ! /usr/bin/grep -qi 'Resource busy' "$output_stage/create.log"; then
    exit 1
  fi
  echo "==> 磁盘映像资源暂忙，重试 $((attempt + 1))/3" >&2
  /bin/rm -f -- "$pending_dmg"
  /bin/sleep "$((attempt * 5))"
done
/usr/bin/hdiutil verify "$pending_dmg"
/bin/mv -f -- "$pending_dmg" "$dmg"
LC_ALL=C /usr/bin/shasum -a 256 "$dmg"
/bin/ls -lh "$dmg"
