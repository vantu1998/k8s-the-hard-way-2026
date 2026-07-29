#!/bin/bash
set -euo pipefail

# IPVS inspection — view and debug IPVS load balancing
#
# Usage: ./ipvs-inspect.sh {list|detail|stats|rate|conn|timeout|scheduler|modules|compare}
#        ./ipvs-inspect.sh detail <service-ip>
#        ./ipvs-inspect.sh compare

ACTION="${1:-list}"
shift || true

case "${ACTION}" in
  list)
    echo "=== IPVS Virtual Servers ==="
    sudo ipvsadm -L -n 2>/dev/null || {
      echo "ipvsadm not installed. Install: sudo apt install -y ipvsadm"
      exit 1
    }
    ;;

  detail)
    SVC_IP="${1:?Usage: $0 detail <service-ip>}"
    echo "=== IPVS Detail for ${SVC_IP} ==="
    sudo ipvsadm -L -n 2>/dev/null | grep -A 10 "${SVC_IP}" || echo "Service not found in IPVS"
    echo ""
    echo "=== Stats ==="
    sudo ipvsadm -L -n --stats 2>/dev/null | grep -A 10 "${SVC_IP}" || true
    echo ""
    echo "=== Rate ==="
    sudo ipvsadm -L -n --rate 2>/dev/null | grep -A 10 "${SVC_IP}" || true
    ;;

  stats)
    echo "=== IPVS Stats (all) ==="
    sudo ipvsadm -L -n --stats 2>/dev/null || echo "ipvsadm not available"
    ;;

  rate)
    echo "=== IPVS Rate (per second) ==="
    sudo ipvsadm -L -n --rate 2>/dev/null || echo "ipvsadm not available"
    ;;

  conn)
    echo "=== IPVS Connections ==="
    sudo ipvsadm -L -n --connection 2>/dev/null || echo "ipvsadm not available"
    echo ""
    echo "Connection count: $(sudo ipvsadm -L -n --connection 2>/dev/null | grep -c '^TCP\|^UDP' || echo 0)"
    ;;

  timeout)
    echo "=== IPVS Timeouts ==="
    sudo ipvsadm -L -n --timeout 2>/dev/null || echo "ipvsadm not available"
    echo ""
    echo "Timeout values (tcp tcpfin udp):"
    sudo ipvsadm -L -n --timeout 2>/dev/null | grep -oP 'Timeout \(.*\): \K.*' || echo "N/A"
    ;;

  scheduler)
    echo "=== IPVS Scheduler ==="
    SCHED=$(kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' 2>/dev/null | grep -oP 'scheduler:\s*\K\w+' || echo "rr")
    echo "Current scheduler: ${SCHED}"
    echo ""
    echo "Available schedulers:"
    echo "  rr   — Round-robin (default)"
    echo "  wrr  — Weighted round-robin"
    echo "  lc   — Least-connection"
    echo "  wlc  — Weighted least-connection"
    echo "  sh   — Source hashing (sticky)"
    echo "  dh   — Destination hashing"
    echo "  sed  — Shortest expected delay"
    echo "  nq   — Never queue"
    ;;

  modules)
    echo "=== IPVS Kernel Modules ==="
    lsmod | grep ip_vs || echo "IPVS modules not loaded"
    echo ""
    echo "=== Required modules ==="
    for mod in ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh ip_vs_lc; do
      if lsmod | grep -q "${mod}"; then
        echo "  ${mod}: loaded"
      else
        echo "  ${mod}: not loaded"
      fi
    done
    ;;

  compare)
    echo "=== iptables vs IPVS Comparison ==="
    echo ""
    echo "--- iptables KUBE rules ---"
    IPTABLES_COUNT=$(sudo iptables -t nat -S 2>/dev/null | grep -c 'KUBE' || echo 0)
    echo "  KUBE chains: $(sudo iptables -t nat -S 2>/dev/null | grep -c '^-N KUBE' || echo 0)"
    echo "  KUBE rules: ${IPTABLES_COUNT}"
    echo ""
    echo "--- IPVS entries ---"
    IPVS_COUNT=$(sudo ipvsadm -L -n 2>/dev/null | grep -c '^TCP\|^UDP' || echo 0)
    echo "  Virtual servers: ${IPVS_COUNT}"
    echo "  Real servers: $(sudo ipvsadm -L -n 2>/dev/null | grep -c 'Masq\|Route\|Tunnel' || echo 0)"
    echo ""
    echo "--- conntrack ---"
    echo "  conntrack entries: $(sudo conntrack -C 2>/dev/null || echo N/A)"
    echo "  conntrack max: $(sudo cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo N/A)"
    echo ""
    if [ "${IPTABLES_COUNT}" -gt 100 ] && [ "${IPVS_COUNT}" -gt 0 ]; then
      echo "  → Mixed mode (iptables + IPVS) — check kube-proxy config"
    elif [ "${IPTABLES_COUNT}" -gt 100 ] && [ "${IPVS_COUNT}" -eq 0 ]; then
      echo "  → iptables mode (no IPVS)"
    elif [ "${IPTABLES_COUNT}" -le 10 ] && [ "${IPVS_COUNT}" -gt 0 ]; then
      echo "  → IPVS mode (iptables for SNAT only)"
    else
      echo "  → Unknown mode"
    fi
    ;;

  *)
    echo "Usage: $0 {list|detail|stats|rate|conn|timeout|scheduler|modules|compare}"
    echo ""
    echo "Examples:"
    echo "  $0 list                  # List all virtual servers"
    echo "  $0 detail 10.96.0.1     # Detail for specific Service"
    echo "  $0 stats                # All stats (conns, packets, bytes)"
    echo "  $0 rate                 # Per-second rate"
    echo "  $0 conn                 # Active connections"
    echo "  $0 timeout              # TCP/UDP timeouts"
    echo "  $0 scheduler            # Current scheduler algorithm"
    echo "  $0 modules              # Check IPVS kernel modules"
    echo "  $0 compare             # Compare iptables vs IPVS"
    exit 1
    ;;
esac
