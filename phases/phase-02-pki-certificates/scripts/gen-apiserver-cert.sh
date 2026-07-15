#!/bin/bash
set -euo pipefail

# Generate kube-apiserver server cert + client certs (etcd, kubelet) using cfssl
# Usage: ./gen-apiserver-cert.sh [cert_dir] [master1_ip] [master2_ip] [master3_ip] [service_ip]

CERT_DIR="${1:-./certs}"
MASTER1_IP="${2:-10.0.0.1}"
MASTER2_IP="${3:-10.0.0.2}"
MASTER3_IP="${4:-10.0.0.3}"
SERVICE_IP="${5:-10.96.0.1}"
DNS_DOMAIN="cluster.local"

# Require CA files
if [ ! -f "${CERT_DIR}/ca.pem" ] || [ ! -f "${CERT_DIR}/etcd-ca.pem" ]; then
    echo "Error: CA files not found in ${CERT_DIR}. Run gen-ca.sh first."
    exit 1
fi

if [ ! -f "${CERT_DIR}/ca-config.json" ]; then
    echo "Error: ca-config.json not found in ${CERT_DIR}. Run gen-ca.sh first."
    exit 1
fi

echo "=== Generating kube-apiserver certificates (cfssl) ==="

# --- apiserver server cert ---
cat > "${CERT_DIR}/apiserver-csr.json" << EOF
{
  "CN": "kube-apiserver",
  "hosts": [
    "kubernetes",
    "kubernetes.default",
    "kubernetes.default.svc",
    "kubernetes.default.svc.${DNS_DOMAIN}",
    "localhost",
    "${SERVICE_IP}",
    "${MASTER1_IP}",
    "${MASTER2_IP}",
    "${MASTER3_IP}",
    "127.0.0.1"
  ],
  "key": {"algo": "rsa", "size": 2048},
  "names": [{"CN": "kube-apiserver"}]
}
EOF
cfssl gencert \
    -ca="${CERT_DIR}/ca.pem" \
    -ca-key="${CERT_DIR}/ca-key.pem" \
    -config="${CERT_DIR}/ca-config.json" \
    -profile=server \
    "${CERT_DIR}/apiserver-csr.json" | cfssljson -bare "${CERT_DIR}/apiserver"
openssl verify -CAfile "${CERT_DIR}/ca.pem" "${CERT_DIR}/apiserver.pem" >/dev/null
echo "  ✓ apiserver.pem (SAN: ${MASTER1_IP}, ${MASTER2_IP}, ${MASTER3_IP}, ${SERVICE_IP}, kubernetes, ...)"

# --- apiserver -> etcd client cert ---
cat > "${CERT_DIR}/apiserver-etcd-client-csr.json" << EOF
{
  "CN": "kube-apiserver-etcd-client",
  "hosts": [],
  "key": {"algo": "rsa", "size": 2048},
  "names": []
}
EOF
cfssl gencert \
    -ca="${CERT_DIR}/etcd-ca.pem" \
    -ca-key="${CERT_DIR}/etcd-ca-key.pem" \
    -config="${CERT_DIR}/ca-config.json" \
    -profile=client \
    "${CERT_DIR}/apiserver-etcd-client-csr.json" | cfssljson -bare "${CERT_DIR}/apiserver-etcd-client"
openssl verify -CAfile "${CERT_DIR}/etcd-ca.pem" "${CERT_DIR}/apiserver-etcd-client.pem" >/dev/null
echo "  ✓ apiserver-etcd-client.pem (signed by etcd-ca)"

# --- apiserver -> kubelet client cert ---
cat > "${CERT_DIR}/apiserver-kubelet-client-csr.json" << EOF
{
  "CN": "kube-apiserver-kubelet-client",
  "hosts": [],
  "key": {"algo": "rsa", "size": 2048},
  "names": []
}
EOF
cfssl gencert \
    -ca="${CERT_DIR}/ca.pem" \
    -ca-key="${CERT_DIR}/ca-key.pem" \
    -config="${CERT_DIR}/ca-config.json" \
    -profile=client \
    "${CERT_DIR}/apiserver-kubelet-client-csr.json" | cfssljson -bare "${CERT_DIR}/apiserver-kubelet-client"
openssl verify -CAfile "${CERT_DIR}/ca.pem" "${CERT_DIR}/apiserver-kubelet-client.pem" >/dev/null
echo "  ✓ apiserver-kubelet-client.pem"

echo ""
echo "=== apiserver certs created in ${CERT_DIR} ==="
