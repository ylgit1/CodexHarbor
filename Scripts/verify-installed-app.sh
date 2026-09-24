#!/bin/zsh
set -euo pipefail

installed_app_path="/Applications/Codex Harbor.app"
backup_app_path="/Applications/.Codex Harbor.previous.app"
helper_path="$installed_app_path/Contents/Helpers/HarborChatGPTAgent"
launch_agent_label="com.codexharbor.chatgpt-agent"
launch_agent_domain="gui/$(id -u)"
health_url="http://127.0.0.1:19473/health"
expected_catalog_version=""
expected_tool_count=""

rollback() {
  local reason="$1"
  echo "安装后验证失败：$reason" >&2
  if [[ ! -e "$backup_app_path" ]]; then
    echo "没有可用的上一版本，无法自动回滚。" >&2
    return 1
  fi

  echo "==> 正在恢复上一版本 Codex Harbor"
  rm -rf "$installed_app_path"
  mv "$backup_app_path" "$installed_app_path"

  if launchctl print "$launch_agent_domain/$launch_agent_label" >/dev/null 2>&1; then
    launchctl kickstart -k "$launch_agent_domain/$launch_agent_label" >/dev/null 2>&1 || true
  fi
  echo "已恢复：$installed_app_path"
  return 0
}

read_expected_catalog() {
  local metadata=""
  metadata="$("$helper_path" --print-tool-catalog 2>/dev/null || true)"
  [[ "$metadata" == *"|"* ]] || return 1

  expected_catalog_version="${metadata%%|*}"
  expected_tool_count="${metadata##*|}"
  [[ -n "$expected_catalog_version" ]] || return 1
  [[ "$expected_tool_count" == <-> ]] || return 1
}

verify_static_install() {
  codesign --verify --deep --strict "$installed_app_path" || return 1
  plutil -lint "$installed_app_path/Contents/Info.plist" >/dev/null || return 1
  [[ -x "$installed_app_path/Contents/MacOS/CodexHarbor" ]] || return 1
  [[ -x "$helper_path" ]] || return 1
  read_expected_catalog || return 1
}

verify_agent_health() {
  local health_json=""
  local attempt=0
  while (( attempt < 24 )); do
    if health_json="$(curl -fsS --max-time 2 "$health_url" 2>/dev/null)"; then
      if [[ "$health_json" == *'"status":"ok"'* ]] \
        && [[ "$health_json" == *"\"toolCatalogVersion\":\"$expected_catalog_version\""* ]] \
        && [[ "$health_json" == *"\"toolCount\":$expected_tool_count"* ]]; then
        echo "$health_json"
        return 0
      fi
    fi
    attempt=$(( attempt + 1 ))
    sleep 0.5
  done

  [[ -n "$health_json" ]] && echo "最后一次 health：$health_json" >&2
  echo "期望 catalog：$expected_catalog_version / $expected_tool_count tools" >&2
  return 1
}

if ! verify_static_install; then
  rollback "应用签名、Info.plist、Helper 或 Tool Catalog 元数据校验失败"
  exit 10
fi

echo "==> 安装包静态验证通过：$expected_catalog_version / $expected_tool_count tools"

if [[ "${1:-}" == "--offline" ]]; then
  exit 0
fi

if ! verify_agent_health; then
  rollback "重载后的 19473 health 与安装包 Tool Catalog 不一致"
  exit 11
fi

echo "==> 安装后健康检查通过，清理上一版本备份"
rm -rf "$backup_app_path"
echo "$installed_app_path"
