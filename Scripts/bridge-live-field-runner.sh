#!/bin/zsh
# Opt-in, detached live HTTPS round-trip. Keeps running when Harbor Agent restarts.
set -uo pipefail

project_root="${CODEX_HARBOR_FIELD_ROOT:-${0:A:h:h}}"
config="$HOME/Library/Application Support/CodexHarbor/ChatGPTBridge/config.json"
status_file="/tmp/codexharbor-https-field.status"
log_file="/tmp/codexharbor-https-field.log"
agent_label="gui/$(id -u)/com.codexharbor.chatgpt-agent"

if [[ "${1:-}" == "--detach" ]]; then
  # Spawn from the already-authorized Agent, then detach into a new process
  # session so an Agent restart cannot cancel the supervising test process.
  /usr/bin/python3 - "$project_root/Scripts/bridge-live-field-runner.sh" "$project_root" <<'PY'
import os, subprocess, sys
script, root = sys.argv[1:]
with open("/tmp/codexharbor-field-detached.out", "ab", buffering=0) as output:
    process = subprocess.Popen(
        ["/bin/zsh", script], cwd=root, stdin=subprocess.DEVNULL,
        stdout=output, stderr=subprocess.STDOUT, start_new_session=True,
        close_fds=True
    )
print("FIELD: detached supervisor PID", process.pid)
PY
  exit $?
fi

restore_if_needed() {
  local mode=""
  mode="$(/usr/bin/plutil -extract transportMode raw -o - "$config" 2>/dev/null || true)"
  if [[ "$mode" != "secureTunnel" ]]; then
    echo "SUPERVISOR: restoring secureTunnel configuration" >> "$log_file"
    /usr/bin/python3 - "$config" >> "$log_file" 2>&1 <<'PY'
import json, os, sys, tempfile
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    config = json.load(handle)
config["transportMode"] = "secureTunnel"
fd, temporary = tempfile.mkstemp(prefix=".codexharbor-restore-", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(config, handle, ensure_ascii=False, indent=2)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.remove(temporary)
PY
    /bin/launchctl kickstart -k "$agent_label" >> "$log_file" 2>&1 || true
  fi
}

finish() {
  local rc=$?
  trap - EXIT
  restore_if_needed
  # Wait for the independently managed Agent to recover its local endpoint.
  local healthy=false
  local n=0
  while (( n < 35 )); do
    if /usr/bin/curl -fsS --max-time 2 "http://127.0.0.1:19473/health" >/dev/null 2>&1; then
      healthy=true
      break
    fi
    /bin/sleep 1
    n=$(( n + 1 ))
  done
  if (( rc == 0 )) && [[ "$healthy" == true ]]; then
    echo "passed-and-restored" > "$status_file"
  else
    echo "failed-restored-or-recovery-needed (exit=$rc localMCP=$healthy)" > "$status_file"
  fi
  echo "SUPERVISOR: exit=$rc localMCP=$healthy" >> "$log_file"
  # launchctl submit creates a keepalive service. Remove our one-shot job
  # before exiting, otherwise launchd can restart the switch test repeatedly.
  if [[ "${XPC_SERVICE_NAME:-}" == com.codexharbor.https-field-* ]]; then
    /bin/launchctl remove "$XPC_SERVICE_NAME" >/dev/null 2>&1 || true
  fi
}
trap finish EXIT

echo "running" > "$status_file"
echo "SUPERVISOR: starting opt-in HTTPS -> secureTunnel field test" > "$log_file"

current_mode="$(/usr/bin/plutil -extract transportMode raw -o - "$config" 2>/dev/null || true)"
if [[ "$current_mode" != "secureTunnel" ]]; then
  echo "SUPERVISOR: preflight failed: original mode is not secureTunnel" >> "$log_file"
  exit 2
fi

/usr/bin/python3 - "$project_root" "$log_file" <<'PY'
import os, subprocess, sys
root, log = sys.argv[1:]
env = os.environ.copy()
env["CODEX_HARBOR_LIVE_HTTPS_SWITCH"] = "1"
with open(log, "a", encoding="utf-8") as handle:
    try:
        child = subprocess.run(
            ["/usr/bin/swift", "test", "--skip-build", "--filter", "LiveTransportSwitchTests"],
            cwd=root, env=env, stdout=handle, stderr=subprocess.STDOUT,
            timeout=215, check=False,
        )
        sys.exit(child.returncode)
    except subprocess.TimeoutExpired:
        handle.write("SUPERVISOR: runner timed out; initiating forced restore\n")
        sys.exit(124)
PY
exit $?
