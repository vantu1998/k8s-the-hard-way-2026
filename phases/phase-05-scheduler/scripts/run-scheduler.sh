#!/bin/bash
set -euo pipefail

# Run kube-scheduler standalone (without kubeadm static pod)
#
# Usage: ./run-scheduler.sh [kubeconfig] [scheduler_name]
#
# Examples:
#   ./run-scheduler.sh                                    # defaults
#   ./run-scheduler.sh /etc/kubernetes/scheduler.conf
#   ./run-scheduler.sh /tmp/admin.kubeconfig my-scheduler

KUBECONFIG="${1:-/etc/kubernetes/scheduler.conf}"
SCHEDULER_NAME="${2:-default-scheduler}"
K8S_VERSION="v1.33.0"

echo "=== Starting kube-scheduler standalone ==="
echo "  Kubeconfig:      ${KUBECONFIG}"
echo "  Scheduler name:  ${SCHEDULER_NAME}"
echo ""

# --- Verify kubeconfig exists ---
if [ ! -f "${KUBECONFIG}" ]; then
  echo "ERROR: Kubeconfig not found: ${KUBECONFIG}"
  echo "If using kubeadm, kubeconfig is at /etc/kubernetes/scheduler.conf"
  echo "If standalone, create one with kubectl config set-cluster/set-credentials"
  exit 1
fi
echo "  ✓ Kubeconfig present"

# --- Install kube-scheduler if not present ---
if ! command -v kube-scheduler &>/dev/null; then
  echo "Installing kube-scheduler ${K8S_VERSION}..."
  curl -fsSL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kube-scheduler" \
    -o /usr/local/bin/kube-scheduler
  sudo chmod +x /usr/local/bin/kube-scheduler
  echo "  ✓ kube-scheduler installed: $(kube-scheduler --version)"
else
  echo "  ✓ kube-scheduler already installed: $(kube-scheduler --version)"
fi

# --- Check if scheduler is already running ---
if pgrep -x kube-scheduler &>/dev/null; then
  echo "WARNING: kube-scheduler is already running (PID: $(pgrep -x kube-scheduler))"
  echo "  Stop it first: sudo kill $(pgrep -x kube-scheduler)"
  exit 1
fi

# --- Start kube-scheduler ---
echo ""
echo "Starting kube-scheduler..."

sudo kube-scheduler \
  --kubeconfig="${KUBECONFIG}" \
  --scheduler-name="${SCHEDULER_NAME}" \
  --leader-elect=false \
  --secure-port=10259 \
  --bind-address=127.0.0.1 \
  --authentication-kubeconfig="${KUBECONFIG}" \
  --authorization-kubeconfig="${KUBECONFIG}" \
  --v=2 &

SCHEDULER_PID=$!
echo "  ✓ kube-scheduler PID: ${SCHEDULER_PID}"

# --- Wait for scheduler to be ready ---
echo "Waiting for kube-scheduler to be ready..."
for i in $(seq 1 10); do
  if curl -sk "https://127.0.0.1:10259/healthz" 2>/dev/null | grep -q "ok"; then
    echo "  ✓ kube-scheduler is healthy"
    break
  fi
  sleep 1
  if [ "${i}" -eq 10 ]; then
    echo "ERROR: kube-scheduler failed to start"
    echo "Check logs: sudo journalctl -u kube-scheduler -f"
    exit 1
  fi
done

echo ""
echo "=== kube-scheduler running ==="
echo ""
echo "Scheduler is now watching for Pending pods."
echo ""
echo "Next steps:"
echo "  kubectl get pods --watch    # Watch pods get scheduled"
echo "  kubectl get events --sort-by='.lastTimestamp' | grep Scheduled"
echo ""
echo "To increase log verbosity (see Filter/Score):"
echo "  Stop scheduler: sudo kill ${SCHEDULER_PID}"
echo "  Restart with --v=5"
echo ""
echo "To stop: sudo kill ${SCHEDULER_PID}"
