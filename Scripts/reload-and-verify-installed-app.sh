#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
verify_script="$project_root/Scripts/verify-installed-app.sh"
installed_app_path="/Applications/Codex Harbor.app"
backup_app_path="/Applications/.Codex Harbor.previous.app"
launch_agent_label="com.codexharbor.chatgpt-agent"
launch_agent_domain="gui/$(id -u)"
status_file="/tmp/codexharbor-install-verify.status"

echo "running" > "$status_file"
sleep 1

if ! launchctl print "$launch_agent_domain/$launch_agent_label" >/dev/null 2>&1; then
  echo "deferred" > "$status_file"
  echo "Agent 当前未由 launchd 加载；静态安装已验证，保留上一版本供下次运行态验证。"
  exit 0
fi

if ! launchctl kickstart -k "$launch_agent_domain/$launch_agent_label"; then
  echo "restart-failed" > "$status_file"
  echo "Agent 重载失败，交给运行态校验执行回滚。" >&2
fi

if /bin/zsh "$verify_script"; then
  echo "ok" > "$status_file"
  exit 0
fi

echo "rolled-back" > "$status_file"
exit 1
