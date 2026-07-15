#!/bin/bash
set -euo pipefail

# Generate etcd server + peer cert for one etcd node using cfssl
# Usage: ./gen-etcd-cert.sh [cert_dir] [node_name] [node_ip]

CERT_DIR="${1:-./certs}"
NODE_NAME="${2:-etcd-1}"
NODE_IP="${3:-10.0.0.1}"

if [ ! -f "${CERT_DIR}/etcd-ca.pem" ] || [ ! -f "${CERT_DIR}/etcd-ca-key.pem" ]; then
    echo "Error: etcd CA files not found in ${CERT_DIR}. Run gen-ca.sh first."
    exit 1
fi

if [ ! -f "${CERT_DIR}/ca-config.json" ]; then
    echo "Error: ca-config.json not found in ${CERT_DIR}. Run gen-ca.sh first."
    exit 1
fi

echo "=== Generating etcd certs for ${NODE_NAME} (${NODE_IP}) using cfssl ==="

# --- Server cert (profile=peer: serverAuth + clientAuth) ---
cat > "${CERT_DIR}/etcd-server-${NODE_NAME}-csr.json" << EOF
{
  "CN": "etcd-server",
  "hosts": [
    "localhost",
    "${NODE_NAME}",
    "${NODE_IP}",
    "127.0.0.1"
  ],
  "key": {"algo": "rsa", "size": 2048},
  "names": [{"CN": "etcd-server"}]
}
EOF
cfssl gencert \
    -ca="${CERT_DIR}/etcd-ca.pem" \
    -ca-key="${CERT_DIR}/etcd-ca-key.pem" \
    -config="${CERT_DIR}/ca-config.json" \
    -profile=peer \
    "${CERT_DIR}/etcd-server-${NODE_NAME}-csr.json" | cfssljson -bare "${CERT_DIR}/etcd-server-${NODE_NAME}"
openssl verify -CAfile "${CERT_DIR}/etcd-ca.pem" "${CERT_DIR}/etcd-server-${NODE_NAME}.pem" >/dev/null
echo "  ✓ etcd-server-${NODE_NAME}.pem (serverAuth + clientAuth)"

# --- Peer cert (profile=peer: mTLS) ---
cat > "${CERT_DIR}/etcd-peer-${NODE_NAME}-csr.json" << EOF
{
  "CN": "${NODE_NAME}",
  "hosts": [
    "${NODE_NAME}",
    "localhost",
    "${NODE_IP}",
    "127.0.0.1"
  ],
  "key": {"algo": "rsa", "size": 2048},
  "names": [{"CN": "${NODE_NAME}"}]
}
EOF
cfssl gencert \
    -ca="${CERT_DIR}/etcd-ca.pem" \
    -ca-key="${CERT_DIR}/etcd-ca-key.pem" \
    -config="${CERT_DIR}/ca-config.json" \
    -profile=peer \
    "${CERT_DIR}/etcd-peer-${NODE_NAME}-csr.json" | cfssljson -bare "${CERT_DIR}/etcd-peer-${NODE_NAME}"
openssl verify -CAfile "${CERT_DIR}/etcd-ca.pem" "${CERT_DIR}/etcd-peer-${NODE_NAME}.pem" >/dev/null
echo "  ✓ etcd-peer-${NODE_NAME}.pem (mTLS: serverAuth + clientAuth)"

echo ""
echo "=== etcd certs for ${NODE_NAME} created ==="
