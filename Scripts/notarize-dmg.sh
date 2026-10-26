#!/bin/zsh
# Optional release step; requires a Developer ID certificate and a stored notarytool profile.
set -euo pipefail

if [[ $# -ne 2 || ! -f "$1" || -z "$2" ]]; then
  echo "用法：$0 <Codex-Harbor.dmg> <notarytool-keychain-profile>" >&2
  exit 2
fi

project_root="${0:A:h:h}"
dmg="${1:A}"
profile="$2"
identity="${CODEX_HARBOR_SIGN_IDENTITY:-}"
tag="$(git -C "$project_root" describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null || true)"
if [[ -z "$tag" || -n "$(git -C "$project_root" status --porcelain)" || "${dmg:t}" != "Codex-Harbor-${tag}-$(uname -m).dmg" ]]; then
  echo "公证仅允许干净、精确版本标签对应的正式 DMG" >&2
  exit 3
fi
if [[ "$identity" != "Developer ID Application:"* ]]; then
  echo "请先用 Developer ID Application 证书构建，并通过 CODEX_HARBOR_SIGN_IDENTITY 指定同一证书" >&2
  exit 3
fi
"$project_root/Scripts/verify-dmg.sh" "$dmg" --developer-id
/usr/bin/codesign --force --timestamp --sign "$identity" "$dmg"
/usr/bin/codesign --verify "$dmg"
/usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
/usr/bin/xcrun stapler staple "$dmg"
/usr/bin/xcrun stapler validate "$dmg"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose "$dmg"
LC_ALL=C /usr/bin/shasum -a 256 "$dmg"
echo "公证和装订完成；请只发布此最终 DMG，并使用上方的 SHA-256 更新校验清单。"
