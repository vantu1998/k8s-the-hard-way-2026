#!/bin/bash
set -euo pipefail

# Tạo cgroup v2, giới hạn CPU, chạy command trong cgroup đó
# Usage: sudo ./cgroup-cpu-limit.sh <cpu_percent> <command>
# Example: sudo ./cgroup-cpu-limit.sh 50 dd if=/dev/zero of=/dev/null

CGROUP_NAME="lab-cpu-limit"
CPU_PERCENT="${1:?Usage: sudo $0 <cpu_percent> <command>}"
shift
COMMAND="$*"

if [ -z "${COMMAND}" ]; then
    echo "Usage: sudo $0 <cpu_percent> <command>"
    echo "Example: sudo $0 50 dd if=/dev/zero of=/dev/null"
    exit 1
fi

# Kiểm tra cgroups v2
if ! mountpoint -q /sys/fs/cgroup || ! grep -q cgroup2 /proc/mounts; then
    echo "Error: cgroups v2 not found. This script requires cgroups v2."
    exit 1
fi

# Tạo cgroup
mkdir -p "/sys/fs/cgroup/${CGROUP_NAME}"

# Enable cpu controller
echo "+cpu" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true

# Tính cpu.max: percent% của 100000 period
MAX=$(( CPU_PERCENT * 1000 ))
echo "${MAX} 100000" > "/sys/fs/cgroup/${CGROUP_NAME}/cpu.max"

echo "=== cgroup: ${CGROUP_NAME} ==="
echo "  CPU limit: ${CPU_PERCENT}% (${MAX}/100000)"
echo "  Command: ${COMMAND}"
echo ""

# Chạy command trong cgroup
echo $$ > "/sys/fs/cgroup/${CGROUP_NAME}/cgroup.procs"
eval "${COMMAND}" &
CMD_PID=$!

# Đợi command kết thúc
wait "${CMD_PID}" 2>/dev/null || true

# Hiện throttling stats
echo ""
echo "=== CPU stats ==="
cat "/sys/fs/cgroup/${CGROUP_NAME}/cpu.stat"

# Cleanup: chuyển process về root cgroup, xóa cgroup
echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
rmdir "/sys/fs/cgroup/${CGROUP_NAME}" 2>/dev/null || true

echo "=== Done ==="
