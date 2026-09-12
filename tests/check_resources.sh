#!/usr/bin/env bash
set -euo pipefail
avail_kb="$(df -Pk / | awk 'NR==2{print $4}')"
mem_avail="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
[ "$avail_kb" -gt 1048576 ] || { echo "less than 1 GiB free disk"; exit 1; }
[ "$mem_avail" -gt 128 ] || { echo "less than 128 MiB free memory"; exit 1; }
echo "disk $((avail_kb/1024)) MiB free, memory ${mem_avail} MiB available"
