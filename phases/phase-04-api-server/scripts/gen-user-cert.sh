#!/bin/bash
set -euo pipefail

# Generate user client cert for Kubernetes RBAC testing
# CN = username, O = group(s)
#
# Usage: ./gen-user-cert.sh <username> <group1>[,group2,...] [cert_dir] [output_dir]
#
# Examples:
#   ./gen-user-cert.sh alice dev                    # CN=alice, O=dev
#   ./gen-user-cert.sh bob dev,admins               # CN=bob, O=dev + O=admins
#   ./gen-user-cert.sh alice dev /etc/kubernetes/pki /tmp

USERNAME="${1:?Usage: $0 <username> <groups> [ca_dir] [output_dir]}"
GROUPS="${2:?Missing groups (comma-separated, e.g. dev or dev,admins)}"
CA_DIR="${3:-/etc/kubernetes/pki}"
OUTPUT_DIR="${4:-/tmp}"

# --- Verify CA files exist ---
if [ ! -f "${CA_DIR}/ca.crt" ] || [ ! -f "${CA_DIR}/ca-key.pem" ]; then
  echo "ERROR: CA files not found in ${CA_DIR}"
  echo "Need ca.crt and ca-key.pem from Phase 2."
  exit 1
fi

echo "=== Generating user cert: CN=${USERNAME} ==="

# --- Build subject string ---
# Multiple O fields: each group becomes a separate /O= entry
SUBJECT="/CN=${USERNAME}"
IFS=',' read -ra GROUP_ARRAY <<< "${GROUPS}"
for group in "${GROUP_ARRAY[@]}"; do
  SUBJECT="${SUBJECT}/O=${group}"
done
echo "  Subject: ${SUBJECT}"

# --- Generate private key ---
KEY_FILE="${OUTPUT_DIR}/${USERNAME}-key.pem"
openssl genrsa -out "${KEY_FILE}" 2048 2>/dev/null
echo "  ✓ Private key: ${KEY_FILE}"

# --- Generate CSR ---
CSR_FILE="${OUTPUT_DIR}/${USERNAME}.csr"
openssl req -new -key "${KEY_FILE}" -out "${CSR_FILE}" -subj "${SUBJECT}" 2>/dev/null
echo "  ✓ CSR: ${CSR_FILE}"

# --- Sign CSR with Kubernetes CA ---
CERT_FILE="${OUTPUT_DIR}/${USERNAME}.pem"
openssl x509 -req -in "${CSR_FILE}" \
  -CA "${CA_DIR}/ca.crt" \
  -CAkey "${CA_DIR}/ca-key.pem" \
  -CAcreateserial -out "${CERT_FILE}" -days 365 2>/dev/null
echo "  ✓ Certificate: ${CERT_FILE}"

# --- Verify ---
openssl verify -CAfile "${CA_DIR}/ca.crt" "${CERT_FILE}" >/dev/null
echo "  ✓ Verified against CA"

# --- Show cert info ---
echo ""
echo "=== Certificate info ==="
openssl x509 -in "${CERT_FILE}" -noout -subject -issuer -dates
echo ""

# --- Create kubeconfig ---
KUBECONFIG_FILE="${OUTPUT_DIR}/${USERNAME}.kubeconfig"
echo "=== Creating kubeconfig: ${KUBECONFIG_FILE} ==="

# Extract API server URL from existing kubeconfig or use default
API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "https://127.0.0.1:6443")

kubectl config set-cluster k8s-lab \
  --server="${API_SERVER}" \
  --certificate-authority="${CA_DIR}/ca.crt" \
  --embed-certs=true \
  --kubeconfig="${KUBECONFIG_FILE}" 2>/dev/null

kubectl config set-credentials "${USERNAME}" \
  --client-certificate="${CERT_FILE}" \
  --client-key="${KEY_FILE}" \
  --embed-certs=true \
  --kubeconfig="${KUBECONFIG_FILE}" 2>/dev/null

kubectl config set-context "${USERNAME}@k8s-lab" \
  --cluster=k8s-lab \
  --user="${USERNAME}" \
  --kubeconfig="${KUBECONFIG_FILE}" 2>/dev/null

kubectl config use-context "${USERNAME}@k8s-lab" \
  --kubeconfig="${KUBECONFIG_FILE}" 2>/dev/null

echo "  ✓ Kubeconfig: ${KUBECONFIG_FILE}"
echo ""
echo "=== Usage ==="
echo "  export KUBECONFIG=${KUBECONFIG_FILE}"
echo "  kubectl get pods -n default"
echo ""
echo "  # Test RBAC (as admin):"
echo "  kubectl auth can-i list pods --as=${USERNAME} -n default"
