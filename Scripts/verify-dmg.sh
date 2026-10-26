#!/bin/zsh
# Verify the actual distribution image without touching /Applications or system proxy settings.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ! -f "$1" || ( $# -eq 2 && "$2" != "--developer-id" ) ]]; then
  echo "用法：$0 <Codex-Harbor.dmg> [--developer-id]" >&2
  exit 2
fi

dmg="${1:A}"
mountpoint="$(/usr/bin/mktemp -d /tmp/codex-harbor-mount.XXXXXX)"
install_stage=""
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then
    /usr/bin/hdiutil detach -quiet "$mountpoint" || /usr/bin/hdiutil detach -force -quiet "$mountpoint" || true
  fi
  if [[ -n "$install_stage" ]]; then /bin/rm -rf -- "$install_stage"; fi
  /bin/rmdir "$mountpoint" 2>/dev/null || true
}
trap cleanup EXIT
install_stage="$(/usr/bin/mktemp -d /tmp/codex-harbor-install.XXXXXX)"

/usr/bin/hdiutil verify "$dmg"
/usr/bin/hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mountpoint" "$dmg"
mounted=true

mounted_app="$mountpoint/Codex Harbor.app"
copied_app="$install_stage/Codex Harbor.app"
[[ -L "$mountpoint/Applications" && "$(/usr/bin/readlink "$mountpoint/Applications")" == /Applications ]]
[[ -x "$mounted_app/Contents/MacOS/CodexHarbor" ]]
[[ -x "$mounted_app/Contents/Helpers/HarborChatGPTAgent" ]]
[[ -x "$mounted_app/Contents/Resources/Xray/$(uname -m)/xray" ]]
/usr/bin/codesign --verify --deep --strict "$mounted_app"
/usr/bin/plutil -lint "$mounted_app/Contents/Info.plist"
if [[ "${2:-}" == "--developer-id" ]]; then
  for signed_code in "$mounted_app" \
    "$mounted_app/Contents/Helpers/HarborChatGPTAgent" \
    "$mounted_app/Contents/Resources/Xray/$(uname -m)/xray"; do
    signature="$(/usr/bin/codesign -dv --verbose=4 "$signed_code" 2>&1)"
    [[ "$signature" == *"Authority=Developer ID Application:"* \
      && "$signature" == *"(runtime)"* \
      && "$signature" == *"Timestamp="* ]] || {
      echo "缺少 Developer ID、Hardened Runtime 或安全时间戳：$signed_code" >&2
      exit 3
    }
  done
fi

# Exercise the same app-copy step as a Finder drag-install, in an isolated directory.
/usr/bin/ditto "$mounted_app" "$copied_app"
/usr/bin/codesign --verify --deep --strict "$copied_app"
"$copied_app/Contents/Helpers/HarborChatGPTAgent" --print-tool-catalog
"$copied_app/Contents/Resources/Xray/$(uname -m)/xray" version

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$copied_app/Contents/Info.plist")"
commit="$(/usr/libexec/PlistBuddy -c 'Print :HarborGitCommit' "$copied_app/Contents/Info.plist")"
[[ "$("$copied_app/Contents/MacOS/CodexHarbor" print-build-info)" == "v$version|$commit" ]]
echo "DMG 安装副本验证通过：v$version · $commit"
