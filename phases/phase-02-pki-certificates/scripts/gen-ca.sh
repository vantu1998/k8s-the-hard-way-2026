#!/bin/bash
set -euo pipefail

# Generate Kubernetes Root CA + etcd CA + front-proxy CA + SA key pair using cfssl
# Usage: ./gen-ca.sh [output_dir]

CERT_DIR="${1:-./certs}"
CA_EXPIRY="87600h"

mkdir -p "${CERT_DIR}"

echo "=== Generating CAs (cfssl) ==="

# --- ca-config.json (signing config) ---
cat > "${CERT_DIR}/ca-config.json" << 'EOF'
{
  "signing": {
    "default": {
      "expiry": "8760h",
      "usages": ["signing", "key encipherment", "server auth"]
    },
    "profiles": {
      "server": {
        "expiry": "8760h",
        "usages": ["signing", "key encipherment", "server auth"]
      },
      "client": {
        "expiry": "8760h",
        "usages": ["signing", "key encipherment", "client auth"]
      },
      "peer": {
        "expiry": "8760h",
        "usages": ["signing", "key encipherment", "server auth", "client auth"]
      }
    }
  }
}
EOF

# --- Kubernetes CA ---
cat > "${CERT_DIR}/ca-csr.json" << EOF
{
  "CN": "kubernetes-ca",
  "key": {"algo": "rsa", "size": 2048},
  "names": [{"CN": "kubernetes-ca"}],
  "ca": {"expiry": "${CA_EXPIRY}"}
}
EOF
cfssl gencert -initca "${CERT_DIR}/ca-csr.json" | cfssljson -bare "${CERT_DIR}/ca"
echo "  ✓ ca.pem (kubernetes-ca, valid ${CA_EXPIRY})"

# --- Etcd CA ---
cat > "${CERT_DIR}/etcd-ca-csr.json" << EOF
{
  "CN": "etcd-ca",
  "key": {"algo": "rsa", "size": 2048},
  "names": [{"CN": "etcd-ca"}],
  "ca": {"expiry": "${CA_EXPIRY}"}
}
EOF
cfssl gencert -initca "${CERT_DIR}/etcd-ca-csr.json" | cfssljson -bare "${CERT_DIR}/etcd-ca"
echo "  ✓ etcd-ca.pem (etcd-ca, valid ${CA_EXPIRY})"

# --- Front Proxy CA ---
cat > "${CERT_DIR}/front-proxy-ca-csr.json" << EOF
{
  "CN": "kubernetes-front-proxy-ca",
  "key": {"algo": "rsa", "size": 2048},
  "names": [{"CN": "kubernetes-front-proxy-ca"}],
  "ca": {"expiry": "${CA_EXPIRY}"}
}
EOF
cfssl gencert -initca "${CERT_DIR}/front-proxy-ca-csr.json" | cfssljson -bare "${CERT_DIR}/front-proxy-ca"
echo "  ✓ front-proxy-ca.pem (valid ${CA_EXPIRY})"

# --- Service Account key pair (not a cert) ---
openssl genrsa -out "${CERT_DIR}/sa.key" 2048 2>/dev/null
openssl rsa -in "${CERT_DIR}/sa.key" -pubout -out "${CERT_DIR}/sa.pub" 2>/dev/null
echo "  ✓ sa.key + sa.pub"

echo ""
echo "=== CAs created in ${CERT_DIR} ==="
echo ""
echo "IMPORTANT: Keep *-key.pem files secure! CA private keys compromised = cluster compromised."
