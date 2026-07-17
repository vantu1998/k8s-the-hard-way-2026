#!/bin/bash
set -euo pipefail

# etcd snapshot save + restore helper
# Usage:
#   Save:   ./snapshot-restore.sh save [snapshot-file] [endpoint] [cert-dir]
#   Status: ./snapshot-restore.sh status <snapshot-file>
#   Restore: ./snapshot-restore.sh restore <snapshot-file> <node-name> <node-ip> <cluster-spec> [data-dir]
#
# Examples:
#   ./snapshot-restore.sh save
#   ./snapshot-restore.sh save /backup/etcd.db https://192.168.56.11:2379 /etc/etcd
#   ./snapshot-restore.sh status /backup/etcd.db
#   ./snapshot-restore.sh restore /backup/etcd.db controlplane01 192.168.56.11 "controlplane01=https://192.168.56.11:2380,controlplane02=https://192.168.56.12:2380,controlplane03=https://192.168.56.13:2380"

ACTION="${1:?Usage: $0 {save|status|restore} ...}"
CERT_DIR="${CERT_DIR:-/etc/etcd}"
ETCDCTL="etcdctl --cacert=${CERT_DIR}/etcd-ca.pem --cert=${CERT_DIR}/etcd-server.pem --key=${CERT_DIR}/etcd-server-key.pem"

case "${ACTION}" in
  save)
    SNAPSHOT_FILE="${2:-/tmp/etcd-snapshot-$(date +%Y%m%d-%H%M%S).db}"
    ENDPOINT="${3:-https://127.0.0.1:2379}"

    echo "=== Saving etcd snapshot ==="
    echo "  Endpoint: ${ENDPOINT}"
    echo "  File:     ${SNAPSHOT_FILE}"
    echo ""

    ${ETCDCTL} --endpoints="${ENDPOINT}" snapshot save "${SNAPSHOT_FILE}"
    echo ""
    echo "  ✓ Snapshot saved: ${SNAPSHOT_FILE}"

    # Show snapshot status
    echo ""
    ${ETCDCTL} snapshot status "${SNAPSHOT_FILE}" --write-out=table
    ;;

  status)
    SNAPSHOT_FILE="${2:?Usage: $0 status <snapshot-file>}"
    echo "=== Snapshot status: ${SNAPSHOT_FILE} ==="
    echo ""
    etcdctl snapshot status "${SNAPSHOT_FILE}" --write-out=table
    ;;

  restore)
    SNAPSHOT_FILE="${2:?Usage: $0 restore <snapshot-file> <node-name> <node-ip> <cluster-spec> [data-dir]}"
    NODE_NAME="${3:?Missing node-name}"
    NODE_IP="${4:?Missing node-ip}"
    CLUSTER_SPEC="${5:?Missing cluster-spec (e.g. controlplane01=https://192.168.56.11:2380,...)}"
    DATA_DIR="${6:-/var/lib/etcd}"
    CLUSTER_TOKEN="${CLUSTER_TOKEN:-etcd-cluster-2026}"

    echo "=== Restoring etcd from snapshot ==="
    echo "  Snapshot:   ${SNAPSHOT_FILE}"
    echo "  Node:       ${NODE_NAME} (${NODE_IP})"
    echo "  Cluster:    ${CLUSTER_SPEC}"
    echo "  Data dir:   ${DATA_DIR}"
    echo ""

    # Stop etcd if running
    if systemctl is-active --quiet etcd 2>/dev/null; then
      echo "Stopping etcd..."
      sudo systemctl stop etcd
    fi

    # Backup old data dir if exists
    if [ -d "${DATA_DIR}" ]; then
      BACKUP_DIR="${DATA_DIR}.backup-$(date +%Y%m%d-%H%M%S)"
      echo "Backing up old data dir to ${BACKUP_DIR}..."
      sudo mv "${DATA_DIR}" "${BACKUP_DIR}"
    fi

    # Restore
    etcdctl snapshot restore "${SNAPSHOT_FILE}" \
      --name="${NODE_NAME}" \
      --initial-cluster="${CLUSTER_SPEC}" \
      --initial-advertise-peer-urls="https://${NODE_IP}:2380" \
      --initial-cluster-token="${CLUSTER_TOKEN}" \
      --data-dir="${DATA_DIR}"

    echo ""
    echo "  ✓ Restore complete: ${DATA_DIR}"
    echo ""
    echo "Next steps:"
    echo "  1. Repeat restore on other nodes (with their respective --name and --initial-advertise-peer-urls)"
    echo "  2. Start etcd on all nodes: sudo systemctl start etcd"
    echo "  3. Verify: etcdctl endpoint health"
    ;;

  *)
    echo "Usage: $0 {save|status|restore} ..."
    echo ""
    echo "Commands:"
    echo "  save    [snapshot-file] [endpoint] [cert-dir]  — Save snapshot"
    echo "  status  <snapshot-file>                        — Show snapshot status"
    echo "  restore <snapshot-file> <node-name> <node-ip> <cluster-spec> [data-dir] — Restore from snapshot"
    exit 1
    ;;
esac
