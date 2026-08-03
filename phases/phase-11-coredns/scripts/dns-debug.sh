#!/usr/bin/env bash
# dns-debug.sh — DNS debugging toolkit cho Kubernetes
# Dùng để trace DNS issues trong cluster

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
head_()  { echo -e "${CYAN}$*${NC}"; }

# ─── Tạo debug pod tạm thời ───────────────────────────────────────────────────

DNS_DEBUG_POD="dns-debug-$(date +%s)"
DNS_DEBUG_NS="${DNS_DEBUG_NS:-default}"

create_debug_pod() {
  local namespace="${1:-default}"
  local pod_name="${DNS_DEBUG_POD}"

  info "Creating debug pod '${pod_name}' in namespace '${namespace}'..."
  kubectl run "${pod_name}" \
    --image=busybox:1.36 \
    --namespace="${namespace}" \
    --command -- sleep 300

  kubectl wait --for=condition=Ready pod "${pod_name}" \
    --namespace="${namespace}" \
    --timeout=60s

  ok "Debug pod ready: ${pod_name}"
  echo "${pod_name}"
}

delete_debug_pod() {
  local pod_name="${1}"
  local namespace="${2:-default}"
  kubectl delete pod "${pod_name}" --namespace="${namespace}" --ignore-not-found >/dev/null
  ok "Debug pod deleted: ${pod_name}"
}

# ─── DNS Resolution checks ────────────────────────────────────────────────────

# Full DNS health check
dns_health_check() {
  local pod="${1}"
  local namespace="${2:-default}"

  echo ""
  head_ "═══════════════════════════════════════"
  head_ " DNS Health Check"
  head_ "═══════════════════════════════════════"

  # 1. resolv.conf
  echo ""
  info "1. /etc/resolv.conf of pod '${pod}':"
  kubectl exec "${pod}" --namespace="${namespace}" -- cat /etc/resolv.conf

  # 2. CoreDNS reachable?
  local dns_ip
  dns_ip=$(kubectl exec "${pod}" --namespace="${namespace}" -- \
    cat /etc/resolv.conf | grep nameserver | awk '{print $2}' | head -1)

  echo ""
  info "2. CoreDNS reachable? (nameserver: ${dns_ip})"
  if kubectl exec "${pod}" --namespace="${namespace}" -- \
    wget -qO- "http://${dns_ip}:8080/health" 2>/dev/null | grep -q "OK"; then
    ok "CoreDNS health endpoint: OK"
  else
    warn "CoreDNS health endpoint: cannot reach (may be normal from pod)"
  fi

  # 3. Resolve kubernetes Service (basic test)
  echo ""
  info "3. Resolve kubernetes.default.svc.cluster.local:"
  if kubectl exec "${pod}" --namespace="${namespace}" -- \
    nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -q "Address"; then
    ok "Internal DNS: OK"
    kubectl exec "${pod}" --namespace="${namespace}" -- \
      nslookup kubernetes.default.svc.cluster.local 2>&1 | grep "Address"
  else
    err "Internal DNS: FAIL"
    kubectl exec "${pod}" --namespace="${namespace}" -- \
      nslookup kubernetes.default.svc.cluster.local 2>&1 || true
  fi

  # 4. Resolve external
  echo ""
  info "4. Resolve google.com (external):"
  if kubectl exec "${pod}" --namespace="${namespace}" -- \
    nslookup google.com 2>&1 | grep -q "Address"; then
    ok "External DNS: OK"
  else
    err "External DNS: FAIL (check forward plugin / upstream)"
  fi
}

# Resolve DNS name với chi tiết
dns_resolve() {
  local name="${1}"
  local pod="${2}"
  local namespace="${3:-default}"

  echo ""
  info "Resolving '${name}' from pod '${pod}' (ns: ${namespace}):"

  echo ""
  info "-- nslookup --"
  kubectl exec "${pod}" --namespace="${namespace}" -- nslookup "${name}" 2>&1 || true

  echo ""
  info "-- dig (detail) --"
  if kubectl exec "${pod}" --namespace="${namespace}" -- which dig >/dev/null 2>&1; then
    kubectl exec "${pod}" --namespace="${namespace}" -- dig "${name}" 2>&1 || true
  else
    warn "dig not available in this image (use tutum/dnsutils for full dig)"
  fi
}

# ─── Service DNS validation ───────────────────────────────────────────────────

# Kiểm tra Service DNS + endpoints
service_dns_check() {
  local svc_name="${1}"
  local namespace="${2:-default}"

  echo ""
  head_ "═══════════════════════════════════════"
  head_ " Service DNS Check: ${svc_name}.${namespace}"
  head_ "═══════════════════════════════════════"

  # 1. Service exists?
  echo ""
  info "1. Service exists?"
  if kubectl get svc "${svc_name}" --namespace="${namespace}" >/dev/null 2>&1; then
    ok "Service found:"
    kubectl get svc "${svc_name}" --namespace="${namespace}"
  else
    err "Service '${svc_name}' not found in namespace '${namespace}'"
    return 1
  fi

  # 2. ClusterIP?
  local cluster_ip
  cluster_ip=$(kubectl get svc "${svc_name}" --namespace="${namespace}" \
    -o jsonpath='{.spec.clusterIP}')

  if [[ "${cluster_ip}" == "None" ]]; then
    warn "Headless Service (clusterIP: None)"
  else
    ok "ClusterIP: ${cluster_ip}"
  fi

  # 3. Endpoints?
  echo ""
  info "2. Endpoints:"
  local endpoints
  endpoints=$(kubectl get endpoints "${svc_name}" --namespace="${namespace}" \
    -o jsonpath='{.subsets[0].addresses}' 2>/dev/null || echo "none")

  if [[ "${endpoints}" == "null" ]] || [[ "${endpoints}" == "none" ]] || [[ -z "${endpoints}" ]]; then
    err "No endpoints! Pod selector may not match any pods."
    echo ""
    info "-- Service selector --"
    kubectl get svc "${svc_name}" --namespace="${namespace}" \
      -o jsonpath='{.spec.selector}' && echo

    echo ""
    info "-- Pods in namespace (check labels) --"
    kubectl get pod --namespace="${namespace}" --show-labels | head -10
  else
    ok "Endpoints found"
    kubectl get endpoints "${svc_name}" --namespace="${namespace}"
  fi

  # 4. DNS via debug pod
  echo ""
  info "3. DNS test (creating temp debug pod)..."
  local debug_pod
  debug_pod=$(create_debug_pod "${namespace}")

  local fqdn="${svc_name}.${namespace}.svc.cluster.local"
  info "Resolving: ${fqdn}"
  kubectl exec "${debug_pod}" --namespace="${namespace}" -- \
    nslookup "${fqdn}" 2>&1 || true

  delete_debug_pod "${debug_pod}" "${namespace}"
}

# ─── Packet capture ───────────────────────────────────────────────────────────

# Capture DNS traffic trên node
capture_dns_on_node() {
  local node="${1}"
  local duration="${2:-10}"

  info "Capturing DNS traffic on node '${node}' for ${duration}s..."
  warn "Requires SSH access to node"

  ssh "${node}" "sudo tcpdump -i any -n 'port 53' -w /tmp/dns-capture.pcap &
    TCPDUMP_PID=\$!
    sleep ${duration}
    kill \${TCPDUMP_PID} 2>/dev/null
    echo 'Capture done: /tmp/dns-capture.pcap'"

  ok "Capture saved at ${node}:/tmp/dns-capture.pcap"
  info "To read: ssh ${node} sudo tcpdump -r /tmp/dns-capture.pcap -n"
}

# ─── CoreDNS log analysis ─────────────────────────────────────────────────────

# Phân tích CoreDNS log
analyze_coredns_logs() {
  local lines="${1:-200}"

  echo ""
  head_ "═══════════════════════════════════════"
  head_ " CoreDNS Log Analysis (last ${lines} lines)"
  head_ "═══════════════════════════════════════"

  local logs
  logs=$(kubectl -n kube-system logs deploy/coredns --tail="${lines}" 2>/dev/null)

  echo ""
  info "-- Error queries (SERVFAIL) --"
  echo "${logs}" | grep "SERVFAIL" | tail -10 || echo "None"

  echo ""
  info "-- NXDOMAIN queries (not found) --"
  echo "${logs}" | grep "NXDOMAIN" | tail -10 || echo "None"

  echo ""
  info "-- Top query names --"
  echo "${logs}" | grep -oP '"[A-Z]+ IN \K[^\s]+' | sort | uniq -c | sort -rn | head -10 || echo "None (log plugin may be disabled)"

  echo ""
  info "-- Recent errors --"
  echo "${logs}" | grep -i "error\|panic\|fatal" | tail -10 || echo "None"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
usage() {
  echo "DNS Debug Toolkit"
  echo ""
  echo "Usage: $0 <command> [args]"
  echo ""
  echo "Commands:"
  echo "  health <pod> [namespace]          Full DNS health check from pod"
  echo "  resolve <name> <pod> [namespace]  Resolve DNS name from pod"
  echo "  service <svc-name> [namespace]    Check Service DNS + endpoints"
  echo "  capture <node> [duration-sec]     Capture DNS packets on node"
  echo "  analyze [lines]                   Analyze CoreDNS logs"
  echo ""
  echo "Examples:"
  echo "  $0 health debug-pod default"
  echo "  $0 resolve kubernetes.default.svc.cluster.local debug-pod"
  echo "  $0 service my-service staging"
  echo "  $0 capture worker-1 30"
  echo "  $0 analyze 500"
}

CMD="${1:-}"
case "${CMD}" in
  health)   dns_health_check "${2}" "${3:-default}" ;;
  resolve)  dns_resolve "${2}" "${3}" "${4:-default}" ;;
  service)  service_dns_check "${2}" "${3:-default}" ;;
  capture)  capture_dns_on_node "${2}" "${3:-10}" ;;
  analyze)  analyze_coredns_logs "${2:-200}" ;;
  *)        usage; exit 1 ;;
esac
