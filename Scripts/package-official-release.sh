#!/bin/bash
# Runs only on a disposable GitHub runner; never alters a developer Mac's keychain.
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted || "${RUNNER_OS:-}" != macOS ]]; then
  echo "Official packaging must run on a GitHub-hosted macOS runner." >&2
  exit 2
fi
if [[ ! "${VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Missing or invalid release version or commit." >&2
  exit 2
fi
for name in MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD MACOS_NOTARY_APPLE_ID \
            MACOS_NOTARY_TEAM_ID MACOS_NOTARY_APP_PASSWORD; do
  if [[ -z "${!name:-}" ]]; then
    echo "::error::Missing $name. Public release requires Developer ID and Apple notarization."
    exit 2
  fi
done

umask 077
directory=$(/usr/bin/mktemp -d "$RUNNER_TEMP/harbor-release-signing.XXXXXXXX")
keychain="$directory/release.keychain-db"
certificate="$directory/certificate.p12"
cleanup() {
  /usr/bin/security delete-keychain "$keychain" >/dev/null 2>&1 || true
  /bin/rm -rf -- "$directory"
}
trap cleanup EXIT
password=$(/usr/bin/openssl rand -hex 32)
printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | /usr/bin/base64 -D > "$certificate"
/usr/bin/security create-keychain -p "$password" "$keychain"
/usr/bin/security set-keychain-settings -lut 3600 "$keychain"
/usr/bin/security unlock-keychain -p "$password" "$keychain"
/usr/bin/security import "$certificate" -k "$keychain" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
/usr/bin/security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
/usr/bin/security list-keychains -d user -s "$keychain"
/bin/rm -f -- "$certificate"

identity=$(/usr/bin/security find-identity -v -p codesigning "$keychain" |
  /usr/bin/awk -F '"' '/"Developer ID Application: / { print $2 }')
if [[ "$identity" != "Developer ID Application:"* || "$identity" == *$'\n'* ]]; then
  echo "::error::Import exactly one valid Developer ID Application identity with its private key."
  exit 2
fi
/usr/bin/xcrun notarytool store-credentials harbor-release --keychain "$keychain" \
  --apple-id "$MACOS_NOTARY_APPLE_ID" --team-id "$MACOS_NOTARY_TEAM_ID" \
  --password "$MACOS_NOTARY_APP_PASSWORD" >/dev/null
unset MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD MACOS_NOTARY_APPLE_ID \
      MACOS_NOTARY_TEAM_ID MACOS_NOTARY_APP_PASSWORD password

export CODEX_HARBOR_SIGN_IDENTITY="$identity"
export CODEX_HARBOR_SIGN_KEYCHAIN="$keychain"
export CODEX_HARBOR_REQUIRE_DEVELOPER_ID=1
export CODEX_HARBOR_EXPECTED_VERSION="$VERSION"
export CODEX_HARBOR_EXPECTED_COMMIT="${GITHUB_SHA:0:12}"
./Scripts/build-app.sh fast --no-install
./Scripts/create-dmg.sh
source_dmg=$(./Scripts/create-dmg.sh --print-path)
./Scripts/verify-dmg.sh "$source_dmg" --developer-id
# Exercise authenticated launchd/XPC with the same certificate in a temporary
# service. The mounted-copy test above also runs the actual packaged helper.
python3 Scripts/proxy-ipc-smoke.py

/usr/bin/codesign --force --timestamp --sign "$identity" --keychain "$keychain" "$source_dmg"
/usr/bin/codesign --verify "$source_dmg"
/usr/bin/xcrun notarytool submit "$source_dmg" --keychain "$keychain" \
  --keychain-profile harbor-release --wait --output-format json > "$directory/notary.json"
python3 - "$directory/notary.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    result = json.load(source)
if result.get("status") != "Accepted":
    raise SystemExit("Apple did not accept the DMG for notarization.")
PY
/usr/bin/xcrun stapler staple "$source_dmg"
./Scripts/verify-dmg.sh "$source_dmg" --notarized --static-only

asset="Codex-Harbor-v${VERSION}-arm64.dmg"
/bin/cp "$source_dmg" "dist/$asset"
(cd dist && /usr/bin/shasum -a 256 "$asset" > SHA256SUMS)
printf 'ASSET_NAME=%s\n' "$asset" >> "$GITHUB_ENV"
