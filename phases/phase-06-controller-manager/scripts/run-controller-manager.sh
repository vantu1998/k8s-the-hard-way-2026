#!/bin/bash
set -euo pipefail

# Run kube-controller-manager standalone (without kubeadm static pod)
#
# Usage: ./run-controller-manager.sh [kubeconfig]
#
# Examples:
#   ./run-controller-manager.sh                                          # defaults
#   ./run-controller-manager.sh /etc/kubernetes/controller-manager.conf

KUBECONFIG="${1:-/etc/kubernetes/controller-manager.conf}"
K8S_VERSION="v1.33.0"
CLUSTER_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"

echo "=== Starting kube-controller-manager standalone ==="
echo "  Kubeconfig:    ${KUBECONFIG}"
echo "  Cluster CIDR:  ${CLUSTER_CIDR}"
echo "  Service CIDR:  ${SERVICE_CIDR}"
echo ""

# --- Verify kubeconfig exists ---
if [ ! -f "${KUBECONFIG}" ]; then
  echo "ERROR: Kubeconfig not found: ${KUBECONFIG}"
  echo "If using kubeadm, kubeconfig is at /etc/kubernetes/controller-manager.conf"
  exit 1
fi
echo "  ✓ Kubeconfig present"

# --- Verify CA cert exists ---
CERT_DIR="/etc/kubernetes/pki"
if [ ! -f "${CERT_DIR}/ca.crt" ]; then
  echo "ERROR: CA cert not found: ${CERT_DIR}/ca.crt"
  echo "Copy certs from Phase 2 before running this script."
  exit 1
fi
echo "  ✓ CA cert present"

# --- Install kube-controller-manager if not present ---
if ! command -v kube-controller-manager &>/dev/null; then
  echo "Installing kube-controller-manager ${K8S_VERSION}..."
  curl -fsSL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kube-controller-manager" \
    -o /usr/local/bin/kube-controller-manager
  sudo chmod +x /usr/local/bin/kube-controller-manager
  echo "  ✓ kube-controller-manager installed: $(kube-controller-manager --version)"
else
  echo "  ✓ kube-controller-manager already installed: $(kube-controller-manager --version)"
fi

# --- Check if already running ---
if pgrep -x kube-controller-manager &>/dev/null; then
  echo "WARNING: kube-controller-manager is already running (PID: $(pgrep -x kube-controller-manager))"
  echo "  Stop it first: sudo kill $(pgrep -x kube-controller-manager)"
  exit 1
fi

# --- Start kube-controller-manager ---
echo ""
echo "Starting kube-controller-manager..."

sudo kube-controller-manager \
  --kubeconfig="${KUBECONFIG}" \
  --authentication-kubeconfig="${KUBECONFIG}" \
  --authorization-kubeconfig="${KUBECONFIG}" \
  --client-ca-file="${CERT_DIR}/ca.crt" \
  --cluster-cidr="${CLUSTER_CIDR}" \
  --service-cluster-ip-range="${SERVICE_CIDR}" \
  --cluster-signing-cert-file="${CERT_DIR}/ca.crt" \
  --cluster-signing-key-file="${CERT_DIR}/ca.key" \
  --service-account-private-key-file="${CERT_DIR}/sa.key" \
  --root-ca-file="${CERT_DIR}/ca.crt" \
  --allocate-node-cidrs=true \
  --node-cidr-mask-size=24 \
  --leader-elect=false \
  --secure-port=10257 \
  --bind-address=127.0.0.1 \
  --use-service-account-credentials=true \
  --v=2 &

CM_PID=$!
echo "  ✓ kube-controller-manager PID: ${CM_PID}"

# --- Wait for controller-manager to be ready ---
echo "Waiting for kube-controller-manager to be ready..."
for i in $(seq 1 10); do
  if curl -sk "https://127.0.0.1:10257/healthz" 2>/dev/null | grep -q "ok"; then
    echo "  ✓ kube-controller-manager is healthy"
    break
  fi
  sleep 1
  if [ "${i}" -eq 10 ]; then
    echo "ERROR: kube-controller-manager failed to start"
    exit 1
  fi
done

echo ""
echo "=== kube-controller-manager running ==="
echo ""
echo "Controllers are now watching for resource changes."
echo ""
echo "Next steps:"
echo "  kubectl get deploy                    # Deployment controller"
echo "  kubectl get rs                        # ReplicaSet controller"
echo "  kubectl get nodes                     # Node controller"
echo "  kubectl get events --sort-by='.lastTimestamp' | head -20"
echo ""
echo "To increase log verbosity:"
echo "  Stop: sudo kill ${CM_PID}"
echo "  Restart with --v=4 (see reconcile decisions)"
echo ""
echo "To stop: sudo kill ${CM_PID}"
