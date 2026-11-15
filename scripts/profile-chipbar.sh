#!/bin/bash
# Compare ChipBar stable and 2.0 on the same Mac under identical workloads.
# No TCC, accessibility, screen capture or sudo permissions are needed.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
    echo "Usage: bash scripts/profile-chipbar.sh <label> [duration-seconds=60] [pid]" >&2
    echo "Example: bash scripts/profile-chipbar.sh stable-expanded 60" >&2
    exit 2
fi
label="$1"
duration="${2:-60}"
if [[ ! "$duration" =~ ^[0-9]+$ ]] || (( duration < 5 || duration > 600 )); then
    echo "Duration must be 5..600 whole seconds." >&2
    exit 2
fi
if [[ $# -eq 3 ]]; then
    pid="$3"
else
    pids="$(pgrep -x ChipBar || true)"
    if [[ -z "$pids" ]]; then
        echo "No running ChipBar found. Open exactly one version first." >&2
        exit 1
    fi
    if [[ "$(printf '%s\n' "$pids" | wc -l | tr -d ' ')" -ne 1 ]]; then
        echo "More than one ChipBar process is running. Quit extras or pass the intended PID:" >&2
        printf '%s\n' "$pids" >&2
        exit 1
    fi
    pid="$pids"
fi
if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
    echo "Invalid or exited process PID: $pid" >&2
    exit 1
fi
safe_label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9_.-' '_')"
stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
output="${CHIPBAR_PROFILE_OUTPUT:-./chipbar-${safe_label}-${stamp}.csv}"
printf 'time_utc,cpu_percent,rss_mib\n' > "$output"
echo "Sampling process $pid for $duration seconds. Keep menu state and refresh interval unchanged."
echo "Writing $output"
for ((i=0; i<duration; i++)); do
    # ps RSS is KiB. The CPU percentage is a sampled process load, not energy,
    # screen FPS, macmon helper CPU or Activity Monitor's system-wide CPU.
    sample="$(ps -p "$pid" -o %cpu= -o rss= | awk 'NF >= 2 { printf "%.3f,%.3f", $1, $2 / 1024 }')"
    if [[ -z "$sample" ]]; then echo "ChipBar exited at sample $i" >&2; exit 1; fi
    printf '%s,%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$sample" >> "$output"
    sleep 1
done
awk -F, '
NR > 1 {
    cpu += $2; rss += $3; n++
    if ($2 > peak_cpu) peak_cpu = $2
    if ($3 > peak_rss) peak_rss = $3
}
END {
    if (!n) exit 1
    printf "ChipBar CPU: mean %.2f%%, peak %.2f%%\n", cpu/n, peak_cpu
    printf "ChipBar RSS: mean %.1f MiB, peak %.1f MiB\n", rss/n, peak_rss
    printf "Samples: %d (compare equal workloads / screen states)\n", n
}
' "$output"
