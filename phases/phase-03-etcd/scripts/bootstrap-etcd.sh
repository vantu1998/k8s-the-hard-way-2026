#!/bin/bash
set -euo pipefail

# Bootstrap etcd cluster 3 node with mTLS
# Usage: ./bootstrap-etcd.sh <node-name> <node-ip> <etcd-1-ip> <etcd-2-ip> <etcd-3-ip> [cert-dir]
# Example: ./bootstrap-etcd.sh etcd-1 10.0.0.1 10.0.0.1 10.0.0.2 10.0.0.3 /etc/etcd

NODE_NAME="${1:?Usage: $0 <node-name> <node-ip> <etcd-1-ip> <etcd-2-ip> <etcd-3-ip> [cert-dir]}"
NODE_IP="${2:?Missing node-ip}"
ETCD1_IP="${3:?Missing etcd-1-ip}"
ETCD2_IP="${4:?Missing etcd-2-ip}"
ETCD3_IP="${5:?Missing etcd-3-ip}"
CERT_DIR="${6:-/etc/etcd}"
DATA_DIR="/var/lib/etcd"
ETCD_VERSION="v3.5.12"
CLUSTER_TOKEN="etcd-cluster-2026"

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

# --- Build initial-cluster string ---
INITIAL_CLUSTER="etcd-1=https://${ETCD1_IP}:2380,etcd-2=https://${ETCD2_IP}:2380,etcd-3=https://${ETCD3_IP}:2380"

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
  --listen-peer-urls=https://0.0.0.0:2380 \\
  --listen-client-urls=https://0.0.0.0:2379 \\
  --initial-advertise-peer-urls=https://${NODE_IP}:2380 \\
  --advertise-client-urls=https://${NODE_IP}:2379 \\
  --initial-cluster=${INITIAL_CLUSTER} \\
  --initial-cluster-state=new \\
  --initial-cluster-token=${CLUSTER_TOKEN} \\
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
echo "Next steps:"
echo "  1. Run this script on etcd-2 and etcd-3 (with their respective IPs)"
echo "  2. Verify cluster: etcdctl member list --write-out=table"
echo "  3. Verify health:  etcdctl endpoint health"
