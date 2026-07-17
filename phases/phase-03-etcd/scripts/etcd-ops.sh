#!/bin/bash
set -euo pipefail

# etcd operations helper: health, status, member list, compact, defrag, key-stats
# Usage: ./etcd-ops.sh <command> [args]
#
# Commands:
#   health              — Check endpoint health
#   status              — Show endpoint status (table)
#   members             — List cluster members (table)
#   compact [revision]  — Compact to revision (default: current)
#   defrag [endpoint]   — Defrag single node or --cluster
#   defrag-all          — Defrag all nodes sequentially
#   key-stats           — Count keys by resource type (K8s)
#   watch <prefix>      — Watch key prefix
#   backup [file]       — Save snapshot
#   maintenance         — Full maintenance: compact + defrag + status

CERT_DIR="${CERT_DIR:-/etc/etcd}"
ENDPOINTS="${ENDPOINTS:-https://127.0.0.1:2379}"

ETCDCTL="etcdctl \
  --endpoints=${ENDPOINTS} \
  --cacert=${CERT_DIR}/etcd-ca.pem \
  --cert=${CERT_DIR}/etcd-server.pem \
  --key=${CERT_DIR}/etcd-server-key.pem"

# For kubeadm clusters, try kubernetes pki path
if [ ! -f "${CERT_DIR}/etcd-ca.pem" ] && [ -f "/etc/kubernetes/pki/etcd/ca.crt" ]; then
  CERT_DIR="/etc/kubernetes/pki/etcd"
  ETCDCTL="etcdctl \
    --endpoints=${ENDPOINTS} \
    --cacert=${CERT_DIR}/ca.crt \
    --cert=${CERT_DIR}/healthcheck-client.crt \
    --key=${CERT_DIR}/healthcheck-client.key"
fi

ACTION="${1:?Usage: $0 {health|status|members|compact|defrag|defrag-all|key-stats|watch|backup|maintenance}}"

case "${ACTION}" in
  health)
    echo "=== etcd endpoint health ==="
    ${ETCDCTL} endpoint health --cluster
    ;;

  status)
    echo "=== etcd endpoint status ==="
    ${ETCDCTL} endpoint status --cluster --write-out=table
    ;;

  members)
    echo "=== etcd cluster members ==="
    ${ETCDCTL} member list --write-out=table
    ;;

  compact)
    REV="${2:-}"
    if [ -z "${REV}" ]; then
      REV=$(${ETCDCTL} endpoint status --write-out=json | jq -r '.[0].Status.header.revision')
      echo "Current revision: ${REV}"
    fi
    echo "Compacting to revision ${REV}..."
    ${ETCDCTL} compact "${REV}"
    echo "  ✓ Compacted to revision ${REV}"
    ;;

  defrag)
    ENDPOINT="${2:-}"
    if [ -n "${ENDPOINT}" ]; then
      echo "Defragmenting ${ENDPOINT}..."
      ${ETCDCTL} defrag --endpoints="${ENDPOINT}"
    else
      echo "Defragmenting all nodes (sequential)..."
      ${ETCDCTL} defrag --cluster
    fi
    echo "  ✓ Defrag complete"
    ;;

  defrag-all)
    echo "Defragmenting all nodes (sequential)..."
    ${ETCDCTL} defrag --cluster
    echo "  ✓ Defrag complete"
    ;;

  key-stats)
    echo "=== etcd key distribution (Kubernetes) ==="
    echo ""
    total=0
    for prefix in pods services deployments replicasets daemonsets \
      statefulsets jobs cronjobs secrets configmaps namespaces nodes \
      serviceaccounts clusterroles clusterrolebindings roles rolebindings \
      persistentvolumes persistentvolumeclaims leases events \
      ingresses networkpolicies; do
      count=$(${ETCDCTL} get --prefix "/registry/${prefix}/" --keys-only 2>/dev/null \
        | grep -c "^/registry/${prefix}/" 2>/dev/null || echo 0)
      if [ "${count}" -gt 0 ]; then
        printf "  %-30s %5d keys\n" "${prefix}" "${count}"
        total=$((total + count))
      fi
    done
    echo ""
    printf "  %-30s %5d keys\n" "TOTAL" "${total}"
    ;;

  watch)
    PREFIX="${2:?Usage: $0 watch <prefix>}"
    echo "Watching prefix: ${PREFIX}"
    echo "(Press Ctrl+C to stop)"
    echo ""
    ${ETCDCTL} watch --prefix "${PREFIX}"
    ;;

  backup)
    FILE="${2:-/tmp/etcd-backup-$(date +%Y%m%d-%H%M%S).db}"
    echo "Saving snapshot to ${FILE}..."
    ${ETCDCTL} snapshot save "${FILE}"
    echo ""
    ${ETCDCTL} snapshot status "${FILE}" --write-out=table
    ;;

  maintenance)
    echo "=== etcd maintenance ==="
    echo ""

    echo "--- Before ---"
    ${ETCDCTL} endpoint status --cluster --write-out=table
    echo ""

    REV=$(${ETCDCTL} endpoint status --write-out=json | jq -r '.[0].Status.header.revision')
    echo "Compacting to revision ${REV}..."
    ${ETCDCTL} compact "${REV}"
    echo ""

    echo "Defragmenting all nodes..."
    ${ETCDCTL} defrag --cluster
    echo ""

    echo "--- After ---"
    ${ETCDCTL} endpoint status --cluster --write-out=table
    echo ""

    echo "  ✓ Maintenance complete"
    ;;

  *)
    echo "Usage: $0 {health|status|members|compact|defrag|defrag-all|key-stats|watch|backup|maintenance}"
    echo ""
    echo "Commands:"
    echo "  health              — Check endpoint health"
    echo "  status              — Show endpoint status (table)"
    echo "  members             — List cluster members (table)"
    echo "  compact [revision]  — Compact to revision (default: current)"
    echo "  defrag [endpoint]   — Defrag single node or all"
    echo "  defrag-all          — Defrag all nodes sequentially"
    echo "  key-stats           — Count keys by K8s resource type"
    echo "  watch <prefix>      — Watch key prefix for changes"
    echo "  backup [file]       — Save snapshot"
    echo "  maintenance         — Full maintenance: compact + defrag + status"
    echo ""
    echo "Environment variables:"
    echo "  ENDPOINTS  — etcd endpoints (default: https://127.0.0.1:2379)"
    echo "  CERT_DIR   — cert directory (default: /etc/etcd or /etc/kubernetes/pki/etcd)"
    exit 1
    ;;
esac
