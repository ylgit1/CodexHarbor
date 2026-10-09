#!/bin/zsh
set -euo pipefail

# Read-only sampling; does not enable telemetry, alter the app or request
# elevated permissions. Run separately with the main window in front/behind.
samples="${1:-30}"
interval="${2:-2}"
if [[ "$samples" != <-> || "$interval" != <-> ]] || (( samples < 2 || samples > 600 || interval < 1 || interval > 60 )); then
  echo "用法：$0 [samples:2..600] [intervalSeconds:1..60]" >&2
  exit 2
fi

project_root="${0:A:h:h}"
output_root="$project_root/dist/performance"
mkdir -p "$output_root"
timestamp="$(date '+%Y%m%d-%H%M%S')"
output="$output_root/cpu-${timestamp}.csv"
echo "timestamp,process,pid,cpu_percent,rss_kib" > "$output"

for (( i=1; i<=samples; i++ )); do
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  ps -axo pid=,pcpu=,rss=,command= | awk -v now="$now" '
    /\/Contents\/MacOS\/CodexHarbor([[:space:]]|$)/ {
      print now ",app," $1 "," $2 "," $3
    }
    /\/Contents\/Helpers\/HarborChatGPTAgent([[:space:]]|$)/ {
      print now ",agent," $1 "," $2 "," $3
    }
    /\/tunnel-client-runtime([[:space:]]|$)/ {
      print now ",tunnel," $1 "," $2 "," $3
    }
  ' >> "$output"
  if (( i < samples )); then sleep "$interval"; fi
done

awk -F, 'NR > 1 {
  count[$2]++; cpu[$2]+=$4; rss[$2]+=$5;
  if ($4 > maxcpu[$2]) maxcpu[$2]=$4;
  if ($5 > maxrss[$2]) maxrss[$2]=$5
} END {
  printf "%-12s %-10s %-12s %-12s %-13s\n", "Process", "Samples", "Mean CPU%", "Peak CPU%", "Peak RSS MiB"
  for (name in count) printf "%-12s %-10d %-12.2f %-12.2f %-13.1f\n", name, count[name], cpu[name]/count[name], maxcpu[name], maxrss[name]/1024
}' "$output"
echo "CSV: $output"
echo "提示：分别在前台静止、后台静止、切换模式三个场景运行；报告只是采样值，不能替代 Instruments 调用栈分析。"
