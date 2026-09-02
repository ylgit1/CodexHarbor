#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
build_root="$project_root/.build"
distribution_root="$project_root/dist"
app_path="$distribution_root/Codex Harbor.app"

env \
  CLANG_MODULE_CACHE_PATH="$build_root/clang-module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$build_root/swift-module-cache" \
  swift build --disable-sandbox -c release

if [[ -e "$app_path" ]]; then
  previous_path="$distribution_root/Codex Harbor.previous-$(date +%Y%m%d-%H%M%S).app"
  mv "$app_path" "$previous_path"
fi

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$build_root/release/CodexHarbor" "$app_path/Contents/MacOS/CodexHarbor"
cp "$project_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
chmod 755 "$app_path/Contents/MacOS/CodexHarbor"
codesign --force --deep --sign - "$app_path"

echo "$app_path"
