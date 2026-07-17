#!/bin/bash
set -euo pipefail

# Run kube-apiserver standalone (without kubelet/controller-manager)
#
# Usage: ./run-apiserver.sh [cert_dir] [etcd_endpoint] [api_ip]
#
# Examples:
#   ./run-apiserver.sh                                    # defaults
#   ./run-apiserver.sh /etc/kubernetes/pki https://127.0.0.1:2379 192.168.56.11

CERT_DIR="${1:-/etc/kubernetes/pki}"
ETCD_ENDPOINT="${2:-https://127.0.0.1:2379}"
API_IP="${3:-127.0.0.1}"
K8S_VERSION="v1.33.0"
SERVICE_CIDR="10.96.0.0/12"

echo "=== Starting kube-apiserver standalone ==="
echo "  Cert dir:       ${CERT_DIR}"
echo "  etcd endpoint:  ${ETCD_ENDPOINT}"
echo "  API bind:       0.0.0.0:6443"
echo ""

# --- Verify certs exist ---
REQUIRED_CERTS=(
  "${CERT_DIR}/ca.crt"
  "${CERT_DIR}/apiserver.crt"
  "${CERT_DIR}/apiserver.key"
  "${CERT_DIR}/apiserver-etcd-client.crt"
  "${CERT_DIR}/apiserver-etcd-client.key"
  "${CERT_DIR}/sa.pub"
  "${CERT_DIR}/sa.key"
  "${CERT_DIR}/etcd/ca.crt"
)
for cert in "${REQUIRED_CERTS[@]}"; do
  if [ ! -f "${cert}" ]; then
    echo "ERROR: Missing cert: ${cert}"
    echo "Copy certs from Phase 2 before running this script."
    exit 1
  fi
done
echo "  ✓ All certs present"

# --- Install kube-apiserver if not present ---
if ! command -v kube-apiserver &>/dev/null; then
  echo "Installing kube-apiserver ${K8S_VERSION}..."
  curl -fsSL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kube-apiserver" \
    -o /usr/local/bin/kube-apiserver
  sudo chmod +x /usr/local/bin/kube-apiserver
  echo "  ✓ kube-apiserver installed: $(kube-apiserver --version)"
else
  echo "  ✓ kube-apiserver already installed: $(kube-apiserver --version)"
fi

# --- Install kubectl if not present ---
if ! command -v kubectl &>/dev/null; then
  echo "Installing kubectl ${K8S_VERSION}..."
  curl -fsSL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl
  sudo chmod +x /usr/local/bin/kubectl
  echo "  ✓ kubectl installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
else
  echo "  ✓ kubectl already installed"
fi

# --- Create admin cert if not exists ---
if [ ! -f "/tmp/admin.pem" ]; then
  echo "Creating admin cert (CN=kubernetes-admin, O=system:masters)..."
  openssl genrsa -out /tmp/admin-key.pem 2048 2>/dev/null
  openssl req -new -key /tmp/admin-key.pem -out /tmp/admin.csr \
    -subj "/CN=kubernetes-admin/O=system:masters" 2>/dev/null
  openssl x509 -req -in /tmp/admin.csr \
    -CA "${CERT_DIR}/ca.crt" \
    -CAkey "${CERT_DIR}/ca-key.pem" \
    -CAcreateserial -out /tmp/admin.pem -days 365 2>/dev/null
  echo "  ✓ Admin cert created"
fi

# --- Create admin kubeconfig ---
echo "Creating admin kubeconfig..."
kubectl config set-cluster k8s-lab \
  --server="https://${API_IP}:6443" \
  --certificate-authority="${CERT_DIR}/ca.crt" \
  --embed-certs=true \
  --kubeconfig=/tmp/admin.kubeconfig 2>/dev/null

kubectl config set-credentials kubernetes-admin \
  --client-certificate=/tmp/admin.pem \
  --client-key=/tmp/admin-key.pem \
  --embed-certs=true \
  --kubeconfig=/tmp/admin.kubeconfig 2>/dev/null

kubectl config set-context kubernetes-admin@k8s-lab \
  --cluster=k8s-lab \
  --user=kubernetes-admin \
  --kubeconfig=/tmp/admin.kubeconfig 2>/dev/null

kubectl config use-context kubernetes-admin@k8s-lab \
  --kubeconfig=/tmp/admin.kubeconfig 2>/dev/null
echo "  ✓ Admin kubeconfig: /tmp/admin.kubeconfig"

# --- Start kube-apiserver ---
echo ""
echo "Starting kube-apiserver..."

# Check if encryption-provider.yaml exists
ENCRYPTION_FLAG=""
if [ -f "/etc/kubernetes/encryption-provider.yaml" ]; then
  ENCRYPTION_FLAG="--encryption-provider-config=/etc/kubernetes/encryption-provider.yaml"
  echo "  ✓ Encryption at rest: enabled"
else
  echo "  ℹ Encryption at rest: disabled (no /etc/kubernetes/encryption-provider.yaml)"
fi

sudo kube-apiserver \
  --etcd-servers="${ETCD_ENDPOINT}" \
  --etcd-cafile="${CERT_DIR}/etcd/ca.crt" \
  --etcd-certfile="${CERT_DIR}/apiserver-etcd-client.crt" \
  --etcd-keyfile="${CERT_DIR}/apiserver-etcd-client.key" \
  --client-ca-file="${CERT_DIR}/ca.crt" \
  --tls-cert-file="${CERT_DIR}/apiserver.crt" \
  --tls-private-key-file="${CERT_DIR}/apiserver.key" \
  --service-account-key-file="${CERT_DIR}/sa.pub" \
  --service-account-signing-key-file="${CERT_DIR}/sa.key" \
  --service-account-issuer=https://kubernetes.default.svc.cluster.local \
  --service-cluster-ip-range="${SERVICE_CIDR}" \
  --authorization-mode=Node,RBAC \
  --enable-admission-plugins=NodeRestriction,ServiceAccount \
  --anonymous-auth=false \
  --bind-address=0.0.0.0 \
  --secure-port=6443 \
  --allow-privileged=true \
  ${ENCRYPTION_FLAG} \
  --v=2 &

APISERVER_PID=$!
echo "  ✓ kube-apiserver PID: ${APISERVER_PID}"

# --- Wait for API Server to be ready ---
echo "Waiting for API Server to be ready..."
for i in $(seq 1 15); do
  if curl -sk "https://${API_IP}:6443/healthz" 2>/dev/null | grep -q "ok"; then
    echo "  ✓ API Server is healthy"
    break
  fi
  sleep 1
  if [ "${i}" -eq 15 ]; then
    echo "ERROR: API Server failed to start"
    exit 1
  fi
done

echo ""
echo "=== kube-apiserver running ==="
echo ""
echo "Next steps:"
echo "  export KUBECONFIG=/tmp/admin.kubeconfig"
echo "  kubectl get namespaces"
echo "  kubectl create namespace default"
echo "  kubectl run nginx --image=nginx"
echo ""
echo "To stop: sudo kill ${APISERVER_PID}"
