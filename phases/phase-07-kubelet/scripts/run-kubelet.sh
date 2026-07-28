#!/bin/bash
set -euo pipefail

# Run kubelet standalone (for testing static pods, node registration)
#
# Usage: ./run-kubelet.sh [bootstrap_kubeconfig] [node_name]
#
# Examples:
#   ./run-kubelet.sh /etc/kubernetes/bootstrap-kubelet.conf worker-1
#   ./run-kubelet.sh /etc/kubernetes/kubelet.conf worker-1

KUBECONFIG="${1:-/etc/kubernetes/kubelet.conf}"
NODE_NAME="${2:-$(hostname)}"
K8S_VERSION="v1.33.0"
CERT_DIR="/etc/kubernetes/pki"
MANIFEST_DIR="/etc/kubernetes/manifests"
KUBELET_CONFIG="/var/lib/kubelet/config.yaml"
CRI_SOCKET="/run/containerd/containerd.sock"

echo "=== Starting kubelet standalone ==="
echo "  Kubeconfig:        ${KUBECONFIG}"
echo "  Node name:         ${NODE_NAME}"
echo "  CRI socket:        ${CRI_SOCKET}"
echo "  Static pod path:   ${MANIFEST_DIR}"
echo ""

# --- Verify kubeconfig exists ---
if [ ! -f "${KUBECONFIG}" ]; then
  echo "ERROR: Kubeconfig not found: ${KUBECONFIG}"
  echo "For TLS bootstrap: create bootstrap-kubelet.conf with token"
  echo "For existing node: use /etc/kubernetes/kubelet.conf"
  exit 1
fi
echo "  ✓ Kubeconfig present"

# --- Verify CA cert ---
if [ ! -f "${CERT_DIR}/ca.crt" ]; then
  echo "ERROR: CA cert not found: ${CERT_DIR}/ca.crt"
  echo "Copy certs from Phase 2 before running this script."
  exit 1
fi
echo "  ✓ CA cert present"

# --- Verify CRI socket ---
if [ ! -S "${CRI_SOCKET}" ]; then
  echo "ERROR: CRI socket not found: ${CRI_SOCKET}"
  echo "Install containerd: apt install containerd"
  echo "Or specify different socket: --container-runtime-endpoint"
  exit 1
fi
echo "  ✓ CRI socket present"

# --- Install kubelet if not present ---
if ! command -v kubelet &>/dev/null; then
  echo "Installing kubelet ${K8S_VERSION}..."
  curl -fsSL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubelet" \
    -o /usr/local/bin/kubelet
  sudo chmod +x /usr/local/bin/kubelet
  echo "  ✓ kubelet installed: $(kubelet --version)"
else
  echo "  ✓ kubelet already installed: $(kubelet --version)"
fi

# --- Create kubelet config if not exists ---
if [ ! -f "${KUBELET_CONFIG}" ]; then
  echo "Creating kubelet config..."
  sudo mkdir -p /var/lib/kubelet
  sudo tee "${KUBELET_CONFIG}" > /dev/null <<EOF
apiVersion: kubelet.config.k8s.io/v1
kind: KubeletConfiguration
address: 0.0.0.0
port: 10250
readOnlyPort: 0
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: ${CERT_DIR}/ca.crt
authorization:
  mode: Webhook
cgroupDriver: systemd
clusterDomain: cluster.local
containerRuntimeEndpoint: unix://${CRI_SOCKET}
evictionHard:
  memory.available: "100Mi"
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "15%"
failSwapOn: true
imageGCHighThresholdPercent: 85
imageGCLowThresholdPercent: 80
rotateCertificates: true
serverTLSBootstrap: true
staticPodPath: ${MANIFEST_DIR}
EOF
  echo "  ✓ Kubelet config created: ${KUBELET_CONFIG}"
else
  echo "  ✓ Kubelet config already exists: ${KUBELET_CONFIG}"
fi

# --- Create manifest dir if not exists ---
sudo mkdir -p "${MANIFEST_DIR}"
echo "  ✓ Manifest dir ready: ${MANIFEST_DIR}"

# --- Check if kubelet already running ---
if pgrep -x kubelet &>/dev/null; then
  echo "WARNING: kubelet is already running (PID: $(pgrep -x kubelet))"
  echo "  Stop it first: sudo kill $(pgrep -x kubelet)"
  exit 1
fi

# --- Start kubelet ---
echo ""
echo "Starting kubelet..."

sudo kubelet \
  --config="${KUBELET_CONFIG}" \
  --kubeconfig="${KUBECONFIG}" \
  --hostname-override="${NODE_NAME}" \
  --node-ip="$(hostname -I | awk '{print $1}')" \
  --v=2 &

KUBELET_PID=$!
echo "  ✓ kubelet PID: ${KUBELET_PID}"

# --- Wait for kubelet to be ready ---
echo "Waiting for kubelet to start..."
sleep 3

if sudo systemctl is-active kubelet &>/dev/null 2>&1; then
  echo "  ✓ kubelet is running (systemd)"
elif kill -0 ${KUBELET_PID} 2>/dev/null; then
  echo "  ✓ kubelet is running (PID: ${KUBELET_PID})"
else
  echo "ERROR: kubelet failed to start"
  echo "Check logs: sudo journalctl -u kubelet --no-pager -n 20"
  exit 1
fi

echo ""
echo "=== kubelet running ==="
echo ""
echo "Kubelet is now:"
echo "  - Watching ${MANIFEST_DIR} for static pods"
echo "  - Connecting to API Server via ${KUBECONFIG}"
echo "  - Reporting node status (heartbeat)"
echo ""
echo "Next steps:"
echo "  kubectl get nodes                        # Verify node registered"
echo "  sudo journalctl -u kubelet -f            # Watch kubelet log"
echo "  ls ${MANIFEST_DIR}                       # List static pod manifests"
echo "  kubectl get pod -A | grep ${NODE_NAME}   # See pods on this node"
echo ""
echo "To stop: sudo kill ${KUBELET_PID}"
