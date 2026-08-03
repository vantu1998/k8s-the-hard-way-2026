#!/usr/bin/env bash
# coredns-ops.sh — CoreDNS operational commands
# Dùng: source coredns-ops.sh để load functions, hoặc chạy trực tiếp

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ─── Hàm tiện ích ─────────────────────────────────────────────────────────────

# Kiểm tra CoreDNS health tổng quan
coredns_status() {
  echo ""
  info "=== CoreDNS Status ==="

  echo ""
  info "-- Pods --"
  kubectl -n kube-system get pod -l k8s-app=kube-dns -o wide

  echo ""
  info "-- Deployment --"
  kubectl -n kube-system get deploy coredns

  echo ""
  info "-- Service (kube-dns) --"
  kubectl -n kube-system get svc kube-dns

  echo ""
  info "-- Endpoints --"
  kubectl -n kube-system get endpoints kube-dns

  echo ""
  info "-- CoreDNS ClusterIP --"
  local dns_ip
  dns_ip=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')
  echo "CoreDNS ClusterIP: ${dns_ip}"
}

# Xem Corefile hiện tại (đẹp hơn)
coredns_corefile() {
  info "=== Corefile (ConfigMap kube-system/coredns) ==="
  kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
  echo ""
}

# Xem CoreDNS logs
coredns_logs() {
  local lines="${1:-50}"
  info "=== CoreDNS Logs (last ${lines} lines) ==="
  kubectl -n kube-system logs deploy/coredns --tail="${lines}"
}

# Bật log plugin trong CoreDNS (debug mode)
coredns_log_enable() {
  info "Enabling log plugin in CoreDNS..."
  local corefile
  corefile=$(kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}')

  if echo "${corefile}" | grep -q "^    log$"; then
    warn "log plugin already enabled"
    return 0
  fi

  # Thêm "log" sau "errors"
  local new_corefile
  new_corefile=$(echo "${corefile}" | sed 's/^    errors$/    errors\n    log/')

  kubectl -n kube-system create configmap coredns \
    --from-literal=Corefile="${new_corefile}" \
    --dry-run=client -o yaml | kubectl apply -f -

  ok "log plugin enabled. Waiting for reload (~10s)..."
  sleep 10
  ok "Done. Run: coredns_logs to see DNS queries"
}

# Tắt log plugin
coredns_log_disable() {
  info "Disabling log plugin in CoreDNS..."
  local corefile
  corefile=$(kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}')

  local new_corefile
  new_corefile=$(echo "${corefile}" | grep -v "^    log$")

  kubectl -n kube-system create configmap coredns \
    --from-literal=Corefile="${new_corefile}" \
    --dry-run=client -o yaml | kubectl apply -f -

  ok "log plugin disabled. Waiting for reload (~10s)..."
  sleep 10
}

# Backup Corefile
coredns_backup() {
  local output="${1:-/tmp/coredns-backup-$(date +%Y%m%d-%H%M%S).yaml}"
  kubectl -n kube-system get cm coredns -o yaml > "${output}"
  ok "Corefile backup saved to: ${output}"
}

# Restore Corefile từ backup
coredns_restore() {
  local backup="${1}"
  if [[ -z "${backup}" ]]; then
    err "Usage: coredns_restore <backup-file>"
    return 1
  fi
  if [[ ! -f "${backup}" ]]; then
    err "File not found: ${backup}"
    return 1
  fi

  info "Restoring CoreDNS ConfigMap from: ${backup}"
  kubectl apply -f "${backup}"
  ok "Restored. Waiting for reload (~10s)..."
  sleep 10
}

# Xem CoreDNS metrics
coredns_metrics() {
  local pod
  pod=$(kubectl -n kube-system get pod -l k8s-app=kube-dns -o jsonpath='{.items[0].metadata.name}')
  info "=== CoreDNS Metrics (pod: ${pod}) ==="

  echo ""
  info "-- Cache stats --"
  kubectl -n kube-system exec "${pod}" -- \
    wget -qO- http://localhost:9153/metrics 2>/dev/null | \
    grep -E 'coredns_cache_(size|hits|misses)' | sort

  echo ""
  info "-- Query count by type --"
  kubectl -n kube-system exec "${pod}" -- \
    wget -qO- http://localhost:9153/metrics 2>/dev/null | \
    grep 'coredns_dns_requests_total' | sort

  echo ""
  info "-- Error count --"
  kubectl -n kube-system exec "${pod}" -- \
    wget -qO- http://localhost:9153/metrics 2>/dev/null | \
    grep 'coredns_dns_responses_total.*SERVFAIL\|NXDOMAIN' | sort
}

# Restart CoreDNS pods (không reload config, thực sự restart)
coredns_restart() {
  warn "Restarting CoreDNS pods (rolling restart)..."
  kubectl -n kube-system rollout restart deploy/coredns
  kubectl -n kube-system rollout status deploy/coredns --timeout=60s
  ok "CoreDNS pods restarted"
}

# Test DNS resolution từ debug pod tạm thời
coredns_test() {
  local query="${1:-kubernetes.default.svc.cluster.local}"
  info "Testing DNS resolution: ${query}"

  kubectl run dns-test-tmp \
    --image=busybox:1.36 \
    --rm -it \
    --restart=Never \
    -- nslookup "${query}" 2>/dev/null
}

# ─── Main (nếu chạy trực tiếp) ────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  CMD="${1:-status}"

  case "${CMD}" in
    status)    coredns_status ;;
    corefile)  coredns_corefile ;;
    logs)      coredns_logs "${2:-50}" ;;
    log-on)    coredns_log_enable ;;
    log-off)   coredns_log_disable ;;
    backup)    coredns_backup "${2:-}" ;;
    restore)   coredns_restore "${2:-}" ;;
    metrics)   coredns_metrics ;;
    restart)   coredns_restart ;;
    test)      coredns_test "${2:-kubernetes.default.svc.cluster.local}" ;;
    *)
      echo "Usage: $0 {status|corefile|logs [N]|log-on|log-off|backup [file]|restore <file>|metrics|restart|test [name]}"
      exit 1
      ;;
  esac
fi
