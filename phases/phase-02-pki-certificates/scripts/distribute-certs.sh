#!/bin/bash
set -euo pipefail

# Distribute generated certificates to master and worker nodes
# Usage: ./distribute-certs.sh [cert_dir]

CERT_DIR="${1:-./certs}"

# Cluster configuration
MASTER1_IP="${MASTER1_IP:-192.168.56.11}"
MASTER2_IP="${MASTER2_IP:-192.168.56.12}"
MASTER3_IP="${MASTER3_IP:-192.168.56.13}"
WORKER1_IP="${WORKER1_IP:-192.168.56.21}"
WORKER2_IP="${WORKER2_IP:-192.168.56.22}"

# Options for scp (disable strict host key checking for ease of use in labs)
SCP_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
USER="vagrant" # Change if using a different user

echo "=== Distributing Certificates ==="

# Master nodes
for i in 1 2 3; do
    NODE_IP_VAR="MASTER${i}_IP"
    NODE_IP="${!NODE_IP_VAR}"
    NODE_NAME="master-${i}"
    echo "Distributing to ${NODE_NAME} (${NODE_IP})..."
    
    # Common CA certs + sa keys + apiserver + etcd + scheduler + controller-manager + admin + kubelet
    scp $SCP_OPTS \
        "${CERT_DIR}/ca.crt" "${CERT_DIR}/ca.key" \
        "${CERT_DIR}/etcd-ca.crt" "${CERT_DIR}/etcd-ca.key" \
        "${CERT_DIR}/front-proxy-ca.crt" "${CERT_DIR}/front-proxy-ca.key" \
        "${CERT_DIR}/sa.pub" "${CERT_DIR}/sa.key" \
        "${CERT_DIR}/apiserver.crt" "${CERT_DIR}/apiserver.key" \
        "${CERT_DIR}/apiserver-etcd-client.crt" "${CERT_DIR}/apiserver-etcd-client.key" \
        "${CERT_DIR}/apiserver-kubelet-client.crt" "${CERT_DIR}/apiserver-kubelet-client.key" \
        "${CERT_DIR}/front-proxy-client.crt" "${CERT_DIR}/front-proxy-client.key" \
        "${CERT_DIR}/etcd-server-${i}.crt" "${CERT_DIR}/etcd-server-${i}.key" \
        "${CERT_DIR}/etcd-peer-${i}.crt" "${CERT_DIR}/etcd-peer-${i}.key" \
        "${CERT_DIR}/etcd-healthcheck-client.crt" "${CERT_DIR}/etcd-healthcheck-client.key" \
        "${CERT_DIR}/scheduler.crt" "${CERT_DIR}/scheduler.key" \
        "${CERT_DIR}/controller-manager.crt" "${CERT_DIR}/controller-manager.key" \
        "${CERT_DIR}/admin.crt" "${CERT_DIR}/admin.key" \
        "${CERT_DIR}/kubelet-${NODE_NAME}.crt" "${CERT_DIR}/kubelet-${NODE_NAME}.key" \
        "${USER}@${NODE_IP}:~/"
done

# Worker nodes
for i in 1 2; do
    NODE_IP_VAR="WORKER${i}_IP"
    NODE_IP="${!NODE_IP_VAR}"
    NODE_NAME="worker-${i}"
    echo "Distributing to ${NODE_NAME} (${NODE_IP})..."
    
    # Common CA + kubelet certs for worker
    scp $SCP_OPTS \
        "${CERT_DIR}/ca.crt" \
        "${CERT_DIR}/kubelet-${NODE_NAME}.crt" "${CERT_DIR}/kubelet-${NODE_NAME}.key" \
        "${USER}@${NODE_IP}:~/"
done

echo "=== Done! ==="
