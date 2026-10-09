#!/bin/zsh
set -euo pipefail

# Run from an independent Terminal session AFTER the App is installed.
# Never force-kill Codex Harbor: the approval panel may be waiting for a user.
installed="/Applications/Codex Harbor.app"
approvals="$HOME/Library/Application Support/CodexHarbor/ChatGPTBridge/approvals"
[[ -x "$installed/Contents/MacOS/CodexHarbor" ]] || {
  echo "Codex Harbor 未安装。" >&2
  exit 2
}

# Fail closed if any command is awaiting user approval. Old records expire
# after 90 seconds; ignore older files left behind by a previous crash.
if [[ -d "$approvals" ]] && /usr/bin/find "$approvals" -type f -name '*.json' -mmin -2 | /usr/bin/grep -q .; then
  echo "有待确认的本地操作；请先处理或等待其超时，然后再重启应用。" >&2
  exit 3
fi

current="$(/usr/bin/pgrep -f '/Applications/Codex Harbor.app/Contents/MacOS/CodexHarbor$' || true)"
if [[ -n "$current" ]]; then
  /usr/bin/osascript -e 'tell application id "com.codexharbor.app" to quit'
  for attempt in {1..20}; do
    if ! /usr/bin/pgrep -f '/Applications/Codex Harbor.app/Contents/MacOS/CodexHarbor$' >/dev/null; then break; fi
    sleep 0.5
  done
  if /usr/bin/pgrep -f '/Applications/Codex Harbor.app/Contents/MacOS/CodexHarbor$' >/dev/null; then
    echo "主应用尚未安全退出，不进行强制结束。" >&2
    exit 4
  fi
fi

/usr/bin/open -a "$installed"
for attempt in {1..20}; do
  running="$(/usr/bin/pgrep -f '/Applications/Codex Harbor.app/Contents/MacOS/CodexHarbor$' || true)"
  if [[ -n "$running" && "$running" != "$current" ]]; then
    echo "Codex Harbor 已重新启动，PID：$running"
    exit 0
  fi
  sleep 0.5
done
echo "主程序启动校验失败，请检查 macOS 上的应用状态。" >&2
exit 5
