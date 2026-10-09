#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
build_root="$project_root/.build"
distribution_root="$project_root/dist"
app_path="$distribution_root/Codex Harbor.app"
staging_app_path="$distribution_root/.Codex Harbor.staging.app"
installed_app_path="/Applications/Codex Harbor.app"
installed_staging_path="/Applications/.Codex Harbor.staging.app"
installed_backup_path="/Applications/.Codex Harbor.previous.app"
lock_dir="$build_root/build-app.lock"
lock_pid_file="$lock_dir/pid"

mode="${1:-fast}"
install_app=true
if [[ "${2:-}" == "--no-install" ]]; then
  install_app=false
fi
jobs="${CODEX_HARBOR_BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

acquire_build_lock() {
  if mkdir "$lock_dir" 2>/dev/null; then
    echo "$$" > "$lock_pid_file"
    return 0
  fi

  local existing_pid=""
  if [[ -f "$lock_pid_file" ]]; then
    existing_pid="$(cat "$lock_pid_file" 2>/dev/null || true)"
  fi

  if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "已有 Codex Harbor 打包任务正在运行（PID $existing_pid），避免重复编译。" >&2
    return 3
  fi

  echo "==> 检测到陈旧打包锁，自动清理"
  rm -f "$lock_pid_file"
  rmdir "$lock_dir" 2>/dev/null || {
    echo "无法清理陈旧打包锁：$lock_dir" >&2
    return 3
  }

  mkdir "$lock_dir"
  echo "$$" > "$lock_pid_file"
}

release_build_lock() {
  rm -f "$lock_pid_file"
  rmdir "$lock_dir" 2>/dev/null || true
}

acquire_build_lock
trap release_build_lock EXIT

case "$mode" in
  fast)
    echo "==> Release 快速编译（关闭 WMO，jobs=$jobs）"
    env \
      CLANG_MODULE_CACHE_PATH="$build_root/clang-module-cache" \
      SWIFTPM_MODULECACHE_OVERRIDE="$build_root/swift-module-cache" \
      swift build --disable-sandbox -c release --jobs "$jobs" \
        -Xswiftc -no-whole-module-optimization
    ;;
  full)
    echo "==> Release 完整优化编译（WMO，jobs=$jobs）"
    env \
      CLANG_MODULE_CACHE_PATH="$build_root/clang-module-cache" \
      SWIFTPM_MODULECACHE_OVERRIDE="$build_root/swift-module-cache" \
      swift build --disable-sandbox -c release --jobs "$jobs"
    ;;
  package-only)
    if [[ ! -x "$build_root/release/CodexHarbor" || ! -x "$build_root/release/HarborChatGPTAgent" ]]; then
      echo "缺少 Release 可执行文件，不能仅打包。请先运行：Scripts/build-app.sh fast" >&2
      exit 4
    fi
    echo "==> 跳过编译，直接打包现有 Release 产物"
    ;;
  *)
    echo "用法：$0 [fast|full|package-only] [--no-install]" >&2
    exit 2
    ;;
esac

rm -rf "$staging_app_path"
mkdir -p "$staging_app_path/Contents/MacOS" "$staging_app_path/Contents/Helpers" "$staging_app_path/Contents/Resources"
cp "$build_root/release/CodexHarbor" "$staging_app_path/Contents/MacOS/CodexHarbor"
cp "$build_root/release/HarborChatGPTAgent" "$staging_app_path/Contents/Helpers/HarborChatGPTAgent"
cp "$project_root/Resources/Info.plist" "$staging_app_path/Contents/Info.plist"
# Stamp builds with a monotonic revision and exact Git commit.
build_number="$(git -C "$project_root" rev-list --count HEAD 2>/dev/null || echo 13)"
build_commit="$(git -C "$project_root" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$project_root" status --porcelain 2>/dev/null)" ]]; then
  build_commit="${build_commit}-dirty"
fi
release_tag="$(git -C "$project_root" describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null || true)"
if [[ "$build_number" == <-> ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$staging_app_path/Contents/Info.plist"
fi
if [[ "$release_tag" =~ '^v[0-9]+\\.[0-9]+\\.[0-9]+$' ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${release_tag#v}" "$staging_app_path/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Add :HarborGitCommit string $build_commit" "$staging_app_path/Contents/Info.plist"
echo "==> 版本标记：${release_tag:-development} (${build_number}) · $build_commit"
cp "$project_root/Resources/AppIcon.icns" "$staging_app_path/Contents/Resources/AppIcon.icns"
chmod 755 "$staging_app_path/Contents/MacOS/CodexHarbor" "$staging_app_path/Contents/Helpers/HarborChatGPTAgent"
# Sign with the same certificate on every build so the Agent retains its
# designated requirement (DR) across binary updates. Stable identifiers alone
# do NOT make ad-hoc signatures persistent in macOS TCC.
#
# Explicit CODEX_HARBOR_SIGN_IDENTITY overrides auto-detection, and "-" forces
# ad-hoc signing. Prefer Apple Development for local builds, Developer ID for
# distributed builds with an appropriate notarization workflow.
sign_identity="${CODEX_HARBOR_SIGN_IDENTITY:-auto}"
if [[ "$sign_identity" == "auto" ]]; then
  available_identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
  # If the installed Agent has a certificate, keep using that exact identity;
  # changing from Apple Development to Developer ID would itself reset TCC.
  installed_agent="$installed_app_path/Contents/Helpers/HarborChatGPTAgent"
  if [[ -x "$installed_agent" ]]; then
    prior_signer="$(/usr/bin/codesign -dv --verbose=4 "$installed_agent" 2>&1 |
      /usr/bin/awk -F= '/^Authority=(Apple Development: |Developer ID Application: |Codex Harbor Local Code Signing)/ { if (name == "") name = $2 } END { print name }')"
    if [[ -n "$prior_signer" && "$available_identities" == *"$prior_signer"* ]]; then
      sign_identity="$prior_signer"
      echo "==> 沿用已安装 Agent 的签名证书，避免升级时更换身份"
    fi
  fi
  if [[ "$sign_identity" == "auto" ]]; then
    sign_identity="$(print -r -- "$available_identities" | /usr/bin/awk -F '"' '/"Apple Development: / { if (name == "") name = $2 } END { print name }')"
  fi
  if [[ -z "$sign_identity" ]]; then
    sign_identity="$(print -r -- "$available_identities" | /usr/bin/awk -F '"' '/"Developer ID Application: / { print $2; exit }')"
  fi
  # Free local-only alternative: a persistent self-signed Code Signing
  # identity created once with Keychain Access Certificate Assistant.
  if [[ -z "$sign_identity" ]]; then
    sign_identity="$(print -r -- "$available_identities" | /usr/bin/awk -F '"' '/"Codex Harbor Local Code Signing"/ { if (name == "") name = $2 } END { print name }')"
  fi
  if [[ -z "$sign_identity" ]]; then sign_identity="-"; fi
fi
if [[ "$sign_identity" != "-" ]]; then
  if [[ "$(/usr/bin/security find-identity -v -p codesigning)" != *"$sign_identity"* ]]; then
    echo "未找到有效的签名证书：$sign_identity" >&2
    exit 6
  fi
  echo "==> 稳定代码签名身份：$sign_identity"
else
  echo "==> 警告：没有有效的持久代码签名身份，当前只能 ad-hoc 签名。" >&2
  echo "    更新 Agent 后，macOS 可能要求重新开启辅助功能和屏幕录制授权。" >&2
  echo "    免费方案：用钥匙串访问 → 证书助理创建「Codex Harbor Local Code Signing」自签名代码签名证书。" >&2
  echo "    或者登录 Xcode 的免费 Apple Account / Personal Team 创建开发证书。" >&2
fi
# Sign nested executable first, then the enclosing app. Avoid --deep when
# signing: it can re-sign nested code with an unexpected identity.
codesign --force --sign "$sign_identity" --identifier "com.codexharbor.agent" "$staging_app_path/Contents/Helpers/HarborChatGPTAgent"
codesign --force --sign "$sign_identity" "$staging_app_path"

codesign --verify --deep --strict "$staging_app_path"
plutil -lint "$staging_app_path/Contents/Info.plist"

rm -rf "$app_path"
mv "$staging_app_path" "$app_path"

echo "==> Release 包已生成：$app_path"

if [[ "$install_app" != true ]]; then
  echo "==> --no-install：仅生成 Release App，不替换 /Applications、不重载 Agent"
  echo "$app_path"
  exit 0
fi

echo "==> 安装到 /Applications"
rm -rf "$installed_staging_path" "$installed_backup_path"
/usr/bin/ditto "$app_path" "$installed_staging_path"
codesign --verify --deep --strict "$installed_staging_path"
plutil -lint "$installed_staging_path/Contents/Info.plist"

if [[ -e "$installed_app_path" ]]; then
  mv "$installed_app_path" "$installed_backup_path"
fi

if mv "$installed_staging_path" "$installed_app_path"; then
  echo "==> 新版已替换，保留上一版本直到运行态健康验证完成"
else
  echo "安装新版失败，正在恢复原应用。" >&2
  rm -rf "$installed_staging_path"
  if [[ -e "$installed_backup_path" ]]; then
    mv "$installed_backup_path" "$installed_app_path"
  fi
  exit 5
fi

/bin/zsh "$project_root/Scripts/verify-installed-app.sh" --offline

verify_log="/tmp/codexharbor-install-verify.log"
verify_status="/tmp/codexharbor-install-verify.status"
rm -f "$verify_log" "$verify_status"
nohup /bin/zsh "$project_root/Scripts/reload-and-verify-installed-app.sh" >"$verify_log" 2>&1 &

echo "==> 已安排 Agent 安全重载与运行态校验"
echo "    状态：$verify_status"
echo "    日志：$verify_log"
echo "    若 health/catalog 校验失败，将自动恢复上一版本。"
echo "$installed_app_path"
