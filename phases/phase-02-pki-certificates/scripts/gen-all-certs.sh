#!/bin/bash
set -euo pipefail

# Generate ALL certificates for a Kubernetes cluster (3 master + 2 worker) using cfssl
# Usage: ./gen-all-certs.sh [cert_dir]
# Environment variables for customization:
#   MASTER1_IP, MASTER2_IP, MASTER3_IP, WORKER1_IP, WORKER2_IP
#   K8S_SERVICE_IP, DNS_DOMAIN, LB_IP, LB_DOMAIN

CERT_DIR="${1:-./certs}"
CA_EXPIRY="87600h"
CERT_EXPIRY="8760h"

# Cluster configuration
MASTER1_IP="${MASTER1_IP:-192.168.56.11}"
MASTER2_IP="${MASTER2_IP:-192.168.56.12}"
MASTER3_IP="${MASTER3_IP:-192.168.56.13}"
WORKER1_IP="${WORKER1_IP:-192.168.56.21}"
WORKER2_IP="${WORKER2_IP:-192.168.56.22}"
K8S_SERVICE_IP="${K8S_SERVICE_IP:-10.96.0.1}"
DNS_DOMAIN="${DNS_DOMAIN:-cluster.local}"
LB_IP="${LB_IP:-}"
LB_DOMAIN="${LB_DOMAIN:-}"

mkdir -p "${CERT_DIR}"

# --- Helpers ---

gen_ca() {
    local name=$1 cn=$2
    cat > "${CERT_DIR}/${name}-csr.json" << EOF
{"CN":"${cn}","key":{"algo":"rsa","size":2048},"names":[{"CN":"${cn}"}],"ca":{"expiry":"${CA_EXPIRY}"}}
EOF
    cfssl gencert -initca "${CERT_DIR}/${name}-csr.json" | cfssljson -bare "${CERT_DIR}/${name}"
}

gen_cert() {
    local name=$1 cn=$2 ca_name=$3 profile=$4 hosts=$5 names=$6
    cat > "${CERT_DIR}/${name}-csr.json" << EOF
{"CN":"${cn}","hosts":${hosts},"key":{"algo":"rsa","size":2048},"names":${names}}
EOF
    cfssl gencert \
        -ca="${CERT_DIR}/${ca_name}.pem" \
        -ca-key="${CERT_DIR}/${ca_name}-key.pem" \
        -config="${CERT_DIR}/ca-config.json" \
        -profile="${profile}" \
        "${CERT_DIR}/${name}-csr.json" | cfssljson -bare "${CERT_DIR}/${name}"
}

verify_cert() {
    if openssl verify -CAfile "${CERT_DIR}/$2.pem" "${CERT_DIR}/$1.pem" >/dev/null 2>&1; then
        echo "  ✓ $1.pem"
    else
        echo "  ✗ $1.pem FAILED"
        exit 1
    fi
}

echo "=== Kubernetes Certificate Generator (cfssl) ==="
echo "  Masters: ${MASTER1_IP}, ${MASTER2_IP}, ${MASTER3_IP}"
echo "  Workers: ${WORKER1_IP}, ${WORKER2_IP}"
echo "  Service IP: ${K8S_SERVICE_IP}"
echo "  Load Balancer: ${LB_IP:-none}${LB_DOMAIN:+ (${LB_DOMAIN})}"
echo ""

# --- 0. ca-config.json ---
cat > "${CERT_DIR}/ca-config.json" << 'EOF'
{
  "signing": {
    "default": {"expiry": "8760h", "usages": ["signing", "key encipherment", "server auth"]},
    "profiles": {
      "server": {"expiry": "8760h", "usages": ["signing", "key encipherment", "server auth"]},
      "client": {"expiry": "8760h", "usages": ["signing", "key encipherment", "client auth"]},
      "peer": {"expiry": "8760h", "usages": ["signing", "key encipherment", "server auth", "client auth"]}
    }
  }
}
EOF

# --- 1. CAs ---
echo "--- CAs ---"
gen_ca ca "kubernetes-ca"; echo "  ✓ ca.pem"
gen_ca etcd-ca "etcd-ca"; echo "  ✓ etcd-ca.pem"
gen_ca front-proxy-ca "kubernetes-front-proxy-ca"; echo "  ✓ front-proxy-ca.pem"

openssl genrsa -out "${CERT_DIR}/sa.key" 2048 2>/dev/null
openssl rsa -in "${CERT_DIR}/sa.key" -pubout -out "${CERT_DIR}/sa.pub" 2>/dev/null
echo "  ✓ sa.key + sa.pub"

# --- 2. apiserver ---
echo ""
echo "--- kube-apiserver ---"
APISERVER_HOSTS="[\"kubernetes\",\"kubernetes.default\",\"kubernetes.default.svc\",\"kubernetes.default.svc.${DNS_DOMAIN}\",\"localhost\",\"${K8S_SERVICE_IP}\",\"${MASTER1_IP}\",\"${MASTER2_IP}\",\"${MASTER3_IP}\",\"127.0.0.1\"${LB_IP:+,\"${LB_IP}\"}${LB_DOMAIN:+,\"${LB_DOMAIN}\"}]"

gen_cert apiserver "kube-apiserver" ca server "${APISERVER_HOSTS}" "[{\"CN\":\"kube-apiserver\"}]"
verify_cert apiserver ca

gen_cert apiserver-etcd-client "kube-apiserver-etcd-client" etcd-ca client "[]" "[]"
verify_cert apiserver-etcd-client etcd-ca

gen_cert apiserver-kubelet-client "kube-apiserver-kubelet-client" ca client "[]" "[]"
verify_cert apiserver-kubelet-client ca

# --- 3. etcd (per master) ---
echo ""
echo "--- etcd ---"
for i in 1 2 3; do
    NODE_IP_VAR="MASTER${i}_IP"
    NODE_IP="${!NODE_IP_VAR}"
    NODE_NAME="etcd-${i}"
    ETCD_HOSTS="[\"localhost\",\"${NODE_NAME}\",\"${NODE_IP}\",\"127.0.0.1\"]"

    gen_cert "etcd-server-${i}" "etcd-server" etcd-ca peer "${ETCD_HOSTS}" "[{\"CN\":\"etcd-server\"}]"
    verify_cert "etcd-server-${i}" etcd-ca

    gen_cert "etcd-peer-${i}" "${NODE_NAME}" etcd-ca peer "${ETCD_HOSTS}" "[{\"CN\":\"${NODE_NAME}\"}]"
    verify_cert "etcd-peer-${i}" etcd-ca
done

gen_cert etcd-healthcheck-client "kube-etcd-healthcheck-client" etcd-ca client "[]" "[]"
verify_cert etcd-healthcheck-client etcd-ca

# --- 4. scheduler + controller-manager ---
echo ""
echo "--- scheduler + controller-manager ---"
gen_cert scheduler "system:kube-scheduler" ca client "[]" "[]"
verify_cert scheduler ca

gen_cert controller-manager "system:kube-controller-manager" ca client "[]" "[]"
verify_cert controller-manager ca

# --- 5. admin ---
echo ""
echo "--- admin ---"
gen_cert admin "kubernetes-admin" ca client "[]" "[{\"O\":\"system:masters\"}]"
verify_cert admin ca

# --- 6. front-proxy client ---
echo ""
echo "--- front-proxy ---"
gen_cert front-proxy-client "front-proxy-client" front-proxy-ca client "[]" "[]"
verify_cert front-proxy-client front-proxy-ca

# --- 7. kubelet (per node) ---
echo ""
echo "--- kubelet ---"
for i in 1 2 3; do
    NODE_IP_VAR="MASTER${i}_IP"
    NODE_IP="${!NODE_IP_VAR}"
    NODE_NAME="master-${i}"
    KUBELET_HOSTS="[\"${NODE_NAME}\",\"${NODE_IP}\"]"

    gen_cert "kubelet-${NODE_NAME}" "system:node:${NODE_NAME}" ca peer "${KUBELET_HOSTS}" "[{\"O\":\"system:nodes\"}]"
    verify_cert "kubelet-${NODE_NAME}" ca
done

for i in 1 2; do
    NODE_IP_VAR="WORKER${i}_IP"
    NODE_IP="${!NODE_IP_VAR}"
    NODE_NAME="worker-${i}"
    KUBELET_HOSTS="[\"${NODE_NAME}\",\"${NODE_IP}\"]"

    gen_cert "kubelet-${NODE_NAME}" "system:node:${NODE_NAME}" ca peer "${KUBELET_HOSTS}" "[{\"O\":\"system:nodes\"}]"
    verify_cert "kubelet-${NODE_NAME}" ca
done

# --- Summary ---
echo ""
echo "=== Done! ==="
echo "  Total: $(ls ${CERT_DIR}/*.pem 2>/dev/null | wc -l) PEM files, $(ls ${CERT_DIR}/*.pub 2>/dev/null | wc -l) pub keys"
echo "  Location: ${CERT_DIR}"
echo ""
echo "  IMPORTANT: Secure all *-key.pem files! CA keys compromised = cluster compromised."
