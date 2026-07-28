#!/bin/bash
set -euo pipefail

# Create bootstrap token for TLS bootstrap
# Run this on the master/control-plane node
#
# Usage: ./bootstrap-token.sh [token_id] [token_secret]
#
# Examples:
#   ./bootstrap-token.sh                                    # auto-generate
#   ./bootstrap-token.sh abcdef 0123456789abcdef            # specific token

CERT_DIR="${CERT_DIR:-/etc/kubernetes/pki}"
API_SERVER="${API_SERVER:-https://$(hostname -I | awk '{print $1}'):6443}"

# --- Generate token ---
if [ $# -ge 2 ]; then
  TOKEN_ID="$1"
  TOKEN_SECRET="$2"
else
  TOKEN_ID=$(head -c 3 /dev/urandom | xxd -p)
  TOKEN_SECRET=$(head -c 16 /dev/urandom | xxd -p)
fi

TOKEN="${TOKEN_ID}.${TOKEN_SECRET}"

echo "=== Creating Bootstrap Token ==="
echo "  Token ID:     ${TOKEN_ID}"
echo "  Token Secret: ${TOKEN_SECRET}"
echo "  Full token:   ${TOKEN}"
echo "  API Server:   ${API_SERVER}"
echo ""

# --- Verify kubectl access ---
if ! kubectl get nodes &>/dev/null; then
  echo "ERROR: Cannot access cluster. Ensure kubectl is configured."
  exit 1
fi
echo "  ✓ kubectl access verified"

# --- Create bootstrap token Secret ---
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-token-${TOKEN_ID}
  namespace: kube-system
type: bootstrap.kubernetes.io/token
stringData:
  token-id: "${TOKEN_ID}"
  token-secret: "${TOKEN_SECRET}"
  usage-bootstrap-authentication: "true"
  usage-bootstrap-signing: "true"
  auth-extra-groups: "system:bootstrappers"
EOF
echo "  ✓ Bootstrap token Secret created"

# --- Verify auto-approve RBAC exists ---
if ! kubectl get clusterrolebinding kubeadm:node-autoapprove-bootstrap &>/dev/null; then
  echo "  Creating auto-approve ClusterRoleBinding..."
  cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubeadm:node-autoapprove-bootstrap
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:nodecluster
subjects:
- kind: Group
  name: system:bootstrappers
  apiGroup: rbac.authorization.k8s.io
EOF
  echo "  ✓ Auto-approve RBAC created"
else
  echo "  ✓ Auto-approve RBAC already exists"
fi

# --- Compute CA cert hash ---
if [ -f "${CERT_DIR}/ca.crt" ]; then
  CA_HASH=$(openssl x509 -in "${CERT_DIR}/ca.crt" -pubkey -noout | \
    openssl rsa -pubin -outform DER 2>/dev/null | \
    sha256sum | awk '{print $1}')
  echo "  ✓ CA cert hash computed"
else
  echo "WARNING: CA cert not found at ${CERT_DIR}/ca.crt"
  CA_HASH="<run: openssl x509 -in /etc/kubernetes/pki/ca.crt -pubkey -noout | openssl rsa -pubin -outform DER 2>/dev/null | sha256sum>"
fi

echo ""
echo "=== Bootstrap Token Ready ==="
echo ""
echo "Join command for worker node:"
echo ""
echo "  kubeadm join ${API_SERVER#https://} \\"
echo "    --token ${TOKEN} \\"
echo "    --discovery-token-ca-cert-hash sha256:${CA_HASH}"
echo ""
echo "Or manually:"
echo ""
echo "  # 1. Create bootstrap-kubelet.conf on worker node:"
echo "  cat > /etc/kubernetes/bootstrap-kubelet.conf <<EOF2"
echo "  apiVersion: v1"
echo "  kind: Config"
echo "  clusters:"
echo "  - cluster:"
echo "      certificate-authority: ${CERT_DIR}/ca.crt"
echo "      server: ${API_SERVER}"
echo "    name: k8s-lab"
echo "  contexts:"
echo "  - context:"
echo "      cluster: k8s-lab"
echo "      user: kubelet-bootstrap"
echo "    name: kubelet-bootstrap"
echo "  current-context: kubelet-bootstrap"
echo "  users:"
echo "  - name: kubelet-bootstrap"
echo "    user:"
echo "      token: ${TOKEN}"
echo "  EOF2"
echo ""
echo "  # 2. Start kubelet with bootstrap config:"
echo "  kubelet --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \\"
echo "          --kubeconfig=/etc/kubernetes/kubelet.conf \\"
echo "          --config=/var/lib/kubelet/config.yaml"
echo ""
echo "  # 3. On master, check CSR:"
echo "  kubectl get csr"
echo ""
echo "Token expires: check with 'kubeadm token list'"
echo "To delete token: kubectl delete secret -n kube-system bootstrap-token-${TOKEN_ID}"
