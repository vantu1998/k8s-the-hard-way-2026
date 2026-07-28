#!/bin/bash
set -euo pipefail

# Setup lab nodes with labels and taints for scheduling exercises
#
# Usage: ./setup-lab-nodes.sh [worker_count]
#
# Examples:
#   ./setup-lab-nodes.sh        # 3 workers
#   ./setup-lab-nodes.sh 2      # 2 workers

WORKER_COUNT="${1:-3}"

echo "=== Setting up lab nodes for scheduling exercises ==="
echo "  Worker count: ${WORKER_COUNT}"
echo ""

# --- Get worker nodes ---
WORKERS=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -v control-plane || true)

if [ -z "${WORKERS}" ]; then
  echo "ERROR: No worker nodes found"
  echo "Ensure cluster is running and has worker nodes"
  exit 1
fi

WORKER_ARRAY=(${WORKERS})
ACTUAL_COUNT=${#WORKER_ARRAY[@]}

echo "Found ${ACTUAL_COUNT} worker node(s):"
for w in "${WORKER_ARRAY[@]}"; do
  echo "  - ${w}"
done
echo ""

if [ "${ACTUAL_COUNT}" -lt 2 ]; then
  echo "WARNING: Need at least 2 worker nodes for scheduling exercises"
  echo "Exercises may not work correctly with 1 node"
fi

# --- Label nodes with zone ---
ZONES=("a" "b" "c" "d" "e")
echo "Labeling nodes with zone labels..."
for i in $(seq 0 $(( ACTUAL_COUNT - 1 ))); do
  ZONE=${ZONES[$(( i % ${#ZONES[@]} ))]}
  kubectl label nodes "${WORKER_ARRAY[$i]}" zone="${ZONE}" --overwrite
  echo "  ✓ ${WORKER_ARRAY[$i]} → zone=${ZONE}"
done

# --- Label first node with disktype=ssd ---
if [ "${ACTUAL_COUNT}" -ge 1 ]; then
  kubectl label nodes "${WORKER_ARRAY[0]}" disktype=ssd --overwrite
  echo "  ✓ ${WORKER_ARRAY[0]} → disktype=ssd"
fi

# --- Show result ---
echo ""
echo "=== Node labels ==="
kubectl get nodes --show-labels | awk '{print $1, $6}' | head -20

echo ""
echo "=== Setup complete ==="
echo ""
echo "Nodes are ready for scheduling exercises."
echo ""
echo "To cleanup labels:"
echo "  for n in $(echo "${WORKERS}" | tr '\n' ' '); do"
echo "    kubectl label nodes \$n zone- disktype-"
echo "  done"
