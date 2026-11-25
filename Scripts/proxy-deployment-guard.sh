#!/bin/zsh
# Source from installation/rollback scripts. No live network changes here.
# A missing journal is safe only when no resident restart marker exists.
proxy_runtime_quiescent() {
  local root="$HOME/Library/Application Support/CodexHarbor/NetworkProxy"
  local journal="$root/proxy-agent-journal.json"
  local marker="$root/proxy-agent-active"
  local migration="$root/legacy-migration.json"
  local value key size
  if [[ -e "$marker" || -L "$marker" || -e "$migration" || -L "$migration" ]]; then
    echo "网络代理仍处于运行或迁移状态，请在代理页面明确断开并确认恢复后再部署。" >&2
    return 1
  fi
  if [[ -L "$journal" ]]; then
    echo "代理服务记录路径异常，拒绝部署。" >&2
    return 1
  fi
  if [[ ! -e "$journal" ]]; then return 0; fi
  [[ -f "$journal" ]] || return 1
  size="$(/usr/bin/stat -f '%z' "$journal")" || return 1
  (( size > 0 && size <= 1048576 )) || return 1
  /usr/bin/plutil -lint "$journal" >/dev/null 2>&1 || return 1
  for key in ports routes engines; do
    value="$(/usr/bin/plutil -extract "$key" json -o - "$journal" 2>/dev/null | /usr/bin/tr -d '[:space:]')" || return 1
    [[ "$value" == '[]' || "$value" == '{}' ]] || {
      echo "代理服务仍持有入口或内核，拒绝部署（$key）。" >&2
      return 1
    }
  done
  # pendingLaunches is absent in the first journal schema.
  if /usr/bin/plutil -extract pendingLaunches json -o - "$journal" >/dev/null 2>&1; then
    value="$(/usr/bin/plutil -extract pendingLaunches json -o - "$journal" | /usr/bin/tr -d '[:space:]')" || return 1
    [[ "$value" == '[]' || "$value" == '{}' || "$value" == 'null' ]] || return 1
  fi
  return 0
}

# Only unload the exact user-level proxy job after verifying quiescence.
# ChatGPT Bridge and the usage-card agent are intentionally untouched.
proxy_unload_quiescent_agent() {
  local domain="gui/$(id -u)" label="com.codexharbor.proxy-agent"
  proxy_runtime_quiescent || return 1
  if [[ -x "/Applications/Codex Harbor.app/Contents/Helpers/HarborProxyAgent" ]] ||
      /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
    if /usr/bin/pgrep -f '/Applications/Codex Harbor.app/Contents/MacOS/CodexHarbor$' >/dev/null; then
      echo "请先正常退出已断开代理的主应用，避免部署过程中重新注册服务。" >&2
      return 1
    fi
  fi
  if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
    /bin/launchctl bootout "$domain/$label" || return 1
  fi
  proxy_runtime_quiescent || return 1
  if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
    echo "独立代理服务未确认卸载，拒绝替换应用。" >&2
    return 1
  fi
  return 0
}

# Keep encrypted user settings and recovery evidence before replacing the
# application. Recovery records are evidence, never replay them blindly into
# the live network configuration.
proxy_backup_configuration() {
  local root="$HOME/Library/Application Support/CodexHarbor/NetworkProxy"
  local backup="$root/deployment-backup"
  local temporary name source
  [[ ! -L "$root" ]] || return 1
  if [[ ! -d "$root" ]]; then return 0; fi
  if [[ -e "$backup" || -L "$backup" ]]; then
    echo "已有代理配置备份；请先归档，避免覆盖回退资料。" >&2
    return 1
  fi
  temporary="$(/usr/bin/mktemp -d "$root/.deployment-backup.XXXXXXXX")" || return 1
  /bin/chmod 700 "$temporary" || { /bin/rm -rf "$temporary"; return 1; }
  for name in proxy-settings-v2.enc system-recovery.json active-process.json proxy-agent-journal.json; do
    source="$root/$name"
    if [[ -L "$source" || ( -e "$source" && ! -f "$source" ) ]]; then
      /bin/rm -rf "$temporary"
      return 1
    fi
    if [[ -f "$source" ]]; then
      /usr/bin/install -m 600 "$source" "$temporary/$name" || {
        /bin/rm -rf "$temporary"; return 1
      }
    fi
  done
  /bin/mv "$temporary" "$backup" || { /bin/rm -rf "$temporary"; return 1; }
  echo "已保留加密代理配置及恢复记录（不自动回放系统代理）。"
}
