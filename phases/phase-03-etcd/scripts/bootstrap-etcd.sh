#!/bin/bash
set -euo pipefail

# Bootstrap etcd cluster with mTLS (kubeadm-style dynamic bootstrap)
#
# Usage:
#   ./bootstrap-etcd.sh init <node-name> <node-ip> [cert-dir]
#   ./bootstrap-etcd.sh join <node-name> <node-ip> <existing-node-ip> [cert-dir]
#
# Examples:
#   # Bootstrap first node (single-node cluster):
#   ./bootstrap-etcd.sh init controlplane01 192.168.56.11
#
#   # Join subsequent nodes (runs etcdctl member add automatically):
#   ./bootstrap-etcd.sh join controlplane02 192.168.56.12 192.168.56.11
#   ./bootstrap-etcd.sh join controlplane03 192.168.56.13 192.168.56.11

MODE="${1:?Usage: $0 {init|join} <node-name> <node-ip> [existing-node-ip] [cert-dir]}"
NODE_NAME="${2:?Missing node-name}"
NODE_IP="${3:?Missing node-ip}"
EXISTING_IP="${4:-}"
CERT_DIR="${5:-/etc/etcd}"
DATA_DIR="/var/lib/etcd"
ETCD_VERSION="v3.6.8"
CLUSTER_TOKEN="etcd-cluster-2026"

if [ "${MODE}" != "init" ] && [ "${MODE}" != "join" ]; then
  echo "ERROR: Mode must be 'init' or 'join'"
  exit 1
fi

if [ "${MODE}" = "join" ] && [ -z "${EXISTING_IP}" ]; then
  echo "ERROR: join mode requires <existing-node-ip>"
  exit 1
fi

echo "=== Bootstrap etcd node: ${NODE_NAME} (${NODE_IP}) ==="
echo ""

# --- Install etcd binary if not present ---
if ! command -v etcd &>/dev/null; then
  echo "Installing etcd ${ETCD_VERSION}..."
  curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz" \
    | tar xz -C /tmp
  sudo cp "/tmp/etcd-${ETCD_VERSION}-linux-amd64/etcd" /usr/local/bin/
  sudo cp "/tmp/etcd-${ETCD_VERSION}-linux-amd64/etcdctl" /usr/local/bin/
  sudo chmod +x /usr/local/bin/etcd /usr/local/bin/etcdctl
  echo "  ✓ etcd installed: $(etcd --version | head -1)"
else
  echo "  ✓ etcd already installed: $(etcd --version | head -1)"
fi

# --- Verify certs exist ---
REQUIRED_CERTS=(
  "${CERT_DIR}/etcd-ca.pem"
  "${CERT_DIR}/etcd-server.pem"
  "${CERT_DIR}/etcd-server-key.pem"
  "${CERT_DIR}/etcd-peer.pem"
  "${CERT_DIR}/etcd-peer-key.pem"
)
for cert in "${REQUIRED_CERTS[@]}"; do
  if [ ! -f "${cert}" ]; then
    echo "ERROR: Missing cert: ${cert}"
    echo "Copy etcd certs from Phase 2 before running this script."
    exit 1
  fi
done
echo "  ✓ All certs present in ${CERT_DIR}"

# --- Create data dir ---
sudo mkdir -p "${DATA_DIR}"
echo "  ✓ Data dir: ${DATA_DIR}"

# --- For join mode: register as member first ---
if [ "${MODE}" = "join" ]; then
  echo "Registering ${NODE_NAME} as member in existing cluster..."
  export ETCDCTL_API=3
  MEMBER_OUTPUT=$(etcdctl \
    --endpoints="https://${EXISTING_IP}:2379" \
    --cacert="${CERT_DIR}/etcd-ca.pem" \
    --cert="${CERT_DIR}/etcd-server.pem" \
    --key="${CERT_DIR}/etcd-server-key.pem" \
    member add "${NODE_NAME}" \
    --peer-urls="https://${NODE_IP}:2380")
  echo "${MEMBER_OUTPUT}"
  # Extract ETCD_INITIAL_CLUSTER from member add output
  INITIAL_CLUSTER=$(echo "${MEMBER_OUTPUT}" | grep '^ETCD_INITIAL_CLUSTER=' | cut -d'"' -f2)
  echo "  ✓ Member ${NODE_NAME} added to cluster"
fi

# --- Build initial-cluster + extra flags ---
if [ "${MODE}" = "init" ]; then
  INITIAL_CLUSTER="${NODE_NAME}=https://${NODE_IP}:2380"
  INITIAL_FLAGS="--initial-cluster=${INITIAL_CLUSTER} --initial-cluster-state=new --initial-cluster-token=${CLUSTER_TOKEN}"
else
  INITIAL_FLAGS="--initial-cluster=${INITIAL_CLUSTER} --initial-cluster-state=existing"
fi

# --- Create systemd unit ---
echo "Creating systemd unit..."
sudo tee /etc/systemd/system/etcd.service > /dev/null << EOF
[Unit]
Description=etcd
After=network.target

[Service]
Type=notify
User=root
ExecStart=/usr/local/bin/etcd \\
  --name=${NODE_NAME} \\
  --data-dir=${DATA_DIR} \\
  --listen-peer-urls=https://${NODE_IP}:2380 \\
  --listen-client-urls=https://127.0.0.1:2379,https://${NODE_IP}:2379 \\
  --listen-metrics-urls=http://127.0.0.1:2381 \\
  --initial-advertise-peer-urls=https://${NODE_IP}:2380 \\
  --advertise-client-urls=https://${NODE_IP}:2379 \\
  ${INITIAL_FLAGS} \\
  --client-cert-auth=true \\
  --trusted-ca-file=${CERT_DIR}/etcd-ca.pem \\
  --cert-file=${CERT_DIR}/etcd-server.pem \\
  --key-file=${CERT_DIR}/etcd-server-key.pem \\
  --peer-client-cert-auth=true \\
  --peer-trusted-ca-file=${CERT_DIR}/etcd-ca.pem \\
  --peer-cert-file=${CERT_DIR}/etcd-peer.pem \\
  --peer-key-file=${CERT_DIR}/etcd-peer-key.pem \\
  --heartbeat-interval=100 \\
  --election-timeout=1000 \\
  --snapshot-count=10000 \\
  --watch-progress-notify-interval=5s \\
  --feature-gates=InitialCorruptCheck=true \\
  --auto-compaction-mode=periodic \\
  --auto-compaction-retention=1h
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
echo "  ✓ systemd unit created: /etc/systemd/system/etcd.service"

# --- Enable + start etcd ---
echo "Starting etcd..."
sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd

# --- Wait for etcd to be ready ---
echo "Waiting for etcd to start..."
for i in $(seq 1 10); do
  if sudo systemctl is-active --quiet etcd; then
    echo "  ✓ etcd is running"
    break
  fi
  sleep 1
  if [ "${i}" -eq 10 ]; then
    echo "ERROR: etcd failed to start"
    sudo journalctl -u etcd --no-pager -n 20
    exit 1
  fi
done

# --- Health check ---
echo ""
echo "=== Health check ==="
export ETCDCTL_API=3
etcdctl \
  --endpoints="https://${NODE_IP}:2379" \
  --cacert="${CERT_DIR}/etcd-ca.pem" \
  --cert="${CERT_DIR}/etcd-server.pem" \
  --key="${CERT_DIR}/etcd-server-key.pem" \
  endpoint health 2>/dev/null || echo "  (Health check will pass once all 3 nodes are running)"

echo ""
echo "=== etcd node ${NODE_NAME} bootstrap complete ==="
echo ""
if [ "${MODE}" = "init" ]; then
  echo "Next steps:"
  echo "  1. Join controlplane02: ./bootstrap-etcd.sh join controlplane02 192.168.56.12 ${NODE_IP}"
  echo "  2. Join controlplane03: ./bootstrap-etcd.sh join controlplane03 192.168.56.13 ${NODE_IP}"
  echo "  3. Verify cluster: etcdctl member list --write-out=table"
  echo "  4. Verify health:  etcdctl endpoint health"
else
  echo "Next steps:"
  echo "  1. Verify cluster: etcdctl member list --write-out=table"
  echo "  2. Verify health:  etcdctl endpoint health"
fi
