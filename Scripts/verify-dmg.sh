#!/bin/zsh
# Verify the actual distribution image without touching /Applications or system proxy settings.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 || ! -f "$1" ||
      ( $# -ge 2 && "$2" != "--developer-id" && "$2" != "--notarized" ) ||
      ( $# -eq 3 && ( "$2" != "--notarized" || "$3" != "--static-only" ) ) ]]; then
  echo "用法：$0 <Codex-Harbor.dmg> [--developer-id|--notarized [--static-only]]" >&2
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
if [[ "${2:-}" == "--notarized" ]]; then
  /usr/bin/xcrun stapler validate "$dmg"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi
/usr/bin/hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mountpoint" "$dmg"
mounted=true

mounted_app="$mountpoint/Codex Harbor.app"
copied_app="$install_stage/Codex Harbor.app"
[[ -L "$mountpoint/Applications" && "$(/usr/bin/readlink "$mountpoint/Applications")" == /Applications ]]
[[ -x "$mounted_app/Contents/MacOS/CodexHarbor" ]]
[[ -x "$mounted_app/Contents/Helpers/HarborChatGPTAgent" ]]
[[ -x "$mounted_app/Contents/Helpers/HarborUsageCardAgent" ]]
[[ -x "$mounted_app/Contents/Helpers/HarborProxyAgent" ]]
[[ ! -e "$mounted_app/Contents/Resources/CodexHarbor_HarborUsageCardAgent.bundle/usage-card.js" ]]
[[ ! -e "$mounted_app/Contents/Resources/CodexHarbor_CodexHarbor.bundle/CodexUsageCard-macOS-0.9.5.bundledata" ]]
[[ -x "$mounted_app/Contents/Resources/Xray/$(uname -m)/xray" ]]
[[ -x "$mounted_app/Contents/Resources/Mihomo/$(uname -m)/mihomo" ]]
[[ -f "$mounted_app/Contents/Resources/Xray/$(uname -m)/geoip.dat" ]]
[[ -f "$mounted_app/Contents/Resources/Xray/$(uname -m)/geosite.dat" ]]
/usr/bin/codesign --verify --deep --strict "$mounted_app"
/usr/bin/plutil -lint "$mounted_app/Contents/Info.plist"
if [[ "${2:-}" == "--developer-id" || "${2:-}" == "--notarized" ]]; then
  for signed_code in "$mounted_app" \
    "$mounted_app/Contents/Helpers/HarborChatGPTAgent" \
    "$mounted_app/Contents/Helpers/HarborUsageCardAgent" \
    "$mounted_app/Contents/Helpers/HarborProxyAgent" \
    "$mounted_app/Contents/Resources/Xray/$(uname -m)/xray" \
    "$mounted_app/Contents/Resources/Mihomo/$(uname -m)/mihomo"; do
    signature="$(/usr/bin/codesign -dv --verbose=4 "$signed_code" 2>&1)"
    [[ "$signature" == *"Authority=Developer ID Application:"* \
      && "$signature" == *"(runtime)"* \
      && "$signature" == *"Timestamp="* ]] || {
      echo "缺少 Developer ID、Hardened Runtime 或安全时间戳：$signed_code" >&2
      exit 3
    }
  done
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$mounted_app/Contents/Info.plist")"
commit="$(/usr/libexec/PlistBuddy -c 'Print :HarborGitCommit' "$mounted_app/Contents/Info.plist")"
if [[ ( -n "${CODEX_HARBOR_EXPECTED_VERSION:-}" && "$version" != "$CODEX_HARBOR_EXPECTED_VERSION" ) ||
      ( -n "${CODEX_HARBOR_EXPECTED_COMMIT:-}" && "$commit" != "$CODEX_HARBOR_EXPECTED_COMMIT" ) ]]; then
  echo "DMG 版本或源码提交与发布目标不符。" >&2
  exit 3
fi
if [[ "${3:-}" == "--static-only" ]]; then
  echo "DMG 签名、公证及元数据验证通过：v$version · $commit"
  exit 0
fi

# Exercise the same app-copy step as a Finder drag-install, in an isolated directory.
/usr/bin/ditto "$mounted_app" "$copied_app"
/usr/bin/codesign --verify --deep --strict "$copied_app"
"$copied_app/Contents/Helpers/HarborChatGPTAgent" --print-tool-catalog
"$copied_app/Contents/Helpers/HarborProxyAgent" --verify-package
"$copied_app/Contents/Resources/Xray/$(uname -m)/xray" version
"$copied_app/Contents/Resources/Mihomo/$(uname -m)/mihomo" -v

[[ "$("$copied_app/Contents/MacOS/CodexHarbor" print-build-info)" == "v$version|$commit" ]]
echo "DMG 安装副本验证通过：v$version · $commit"
