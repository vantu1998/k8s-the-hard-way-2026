#!/bin/bash
set -euo pipefail

# kube-proxy operations — inspect and debug Service load balancing
#
# Usage: ./kube-proxy-ops.sh {mode|services|trace-svc|trace-nodeport|conntrack|counters|config|switch|test}
#        ./kube-proxy-ops.sh trace-svc <service-name>
#        ./kube-proxy-ops.sh trace-nodeport <node-port>
#        ./kube-proxy-ops.sh conntrack <service-ip>
#        ./kube-proxy-ops.sh test <service-name> [count]
#        ./kube-proxy-ops.sh switch {iptables|ipvs}

ACTION="${1:-mode}"
shift || true

case "${ACTION}" in
  mode)
    echo "=== kube-proxy Mode ==="
    MODE=$(kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' 2>/dev/null | grep -oP 'mode:\s*\K\w+' || echo "unknown")
    echo "Current mode: ${MODE}"
    echo ""
    echo "=== kube-proxy Pods ==="
    kubectl -n kube-system get pod -l k8s-app=kube-proxy -o wide
    ;;

  services)
    echo "=== All Services ==="
    kubectl get svc -A -o wide
    echo ""
    echo "=== EndpointSlices ==="
    kubectl get endpointslice -A | head -20
    ;;

  trace-svc)
    SVC_NAME="${1:?Usage: $0 trace-svc <service-name>}"
    NAMESPACE="${2:-default}"
    echo "=== Trace Service: ${NAMESPACE}/${SVC_NAME} ==="
    SVC_IP=$(kubectl -n "${NAMESPACE}" get svc "${SVC_NAME}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    SVC_PORT=$(kubectl -n "${NAMESPACE}" get svc "${SVC_NAME}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
    if [ -z "${SVC_IP}" ]; then
      echo "ERROR: Service not found: ${NAMESPACE}/${SVC_NAME}"
      exit 1
    fi
    echo "Service IP: ${SVC_IP}:${SVC_PORT}"
    echo ""
    echo "--- Endpoints ---"
    kubectl -n "${NAMESPACE}" get endpointslice -l "kubernetes.io/service-name=${SVC_NAME}" -o jsonpath='{range .items[*]}{.endpoints[*].addresses[*]}{"\n"}{end}' 2>/dev/null
    echo ""
    echo ""
    echo "--- iptables KUBE-SERVICES ---"
    sudo iptables -t nat -S KUBE-SERVICES 2>/dev/null | grep "${SVC_IP}" || echo "(no iptables rules — may be IPVS/eBPF mode)"
    echo ""
    echo "--- iptables KUBE-SVC chain ---"
    SVC_CHAIN=$(sudo iptables -t nat -S KUBE-SERVICES 2>/dev/null | grep "${SVC_IP}" | grep -o 'KUBE-SVC-[A-Z0-9]*' || echo "")
    if [ -n "${SVC_CHAIN}" ]; then
      sudo iptables -t nat -S "${SVC_CHAIN}" | grep -v "^-N"
      echo ""
      echo "--- iptables KUBE-SEP (DNAT) ---"
      for sep in $(sudo iptables -t nat -S "${SVC_CHAIN}" | grep -o 'KUBE-SEP-[A-Z0-9]*'); do
        sudo iptables -t nat -S "${sep}" | grep DNAT
      done
    fi
    echo ""
    echo "--- IPVS (if IPVS mode) ---"
    sudo ipvsadm -L -n 2>/dev/null | grep -A 5 "${SVC_IP}" || echo "(IPVS not active)"
    ;;

  trace-nodeport)
    NODE_PORT="${1:?Usage: $0 trace-nodeport <node-port>}"
    echo "=== Trace NodePort: ${NODE_PORT} ==="
    echo ""
    echo "--- iptables KUBE-NODEPORTS ---"
    sudo iptables -t nat -S KUBE-NODEPORTS 2>/dev/null | grep "${NODE_PORT}" || echo "(no iptables rules)"
    echo ""
    echo "--- Full chain ---"
    SVC_CHAIN=$(sudo iptables -t nat -S KUBE-NODEPORTS 2>/dev/null | grep "${NODE_PORT}" | grep -o 'KUBE-SVC-[A-Z0-9]*' || echo "")
    if [ -n "${SVC_CHAIN}" ]; then
      echo "KUBE-SVC chain: ${SVC_CHAIN}"
      sudo iptables -t nat -S "${SVC_CHAIN}" | grep -v "^-N"
      echo ""
      echo "KUBE-SEP (DNAT):"
      for sep in $(sudo iptables -t nat -S "${SVC_CHAIN}" | grep -o 'KUBE-SEP-[A-Z0-9]*'); do
        sudo iptables -t nat -S "${sep}" | grep DNAT
      done
    fi
    echo ""
    echo "--- NodePort Services ---"
    kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="NodePort")]}{.metadata.name}{"\t"}{.metadata.namespace}{"\t"}{.spec.ports[0].nodePort}{"\n"}{end}' 2>/dev/null | grep "${NODE_PORT}" || echo "No matching NodePort service"
    ;;

  conntrack)
    SVC_IP="${1:?Usage: $0 conntrack <service-ip>}"
    echo "=== conntrack for ${SVC_IP} ==="
    sudo conntrack -L 2>/dev/null | grep "${SVC_IP}" || echo "No conntrack entries"
    echo ""
    echo "Total conntrack entries: $(sudo conntrack -C 2>/dev/null || echo N/A)"
    echo "Conntrack max: $(sudo cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo N/A)"
    ;;

  counters)
    echo "=== iptables Counters ==="
    echo ""
    echo "--- KUBE-SERVICES (packet count per Service) ---"
    sudo iptables -t nat -L KUBE-SERVICES -v -n 2>/dev/null | head -30 || echo "(no iptables)"
    echo ""
    echo "--- Total KUBE rules ---"
    echo "KUBE chains: $(sudo iptables -t nat -S 2>/dev/null | grep -c '^-N KUBE')"
    echo "KUBE rules: $(sudo iptables -t nat -S 2>/dev/null | grep -c 'KUBE')"
    ;;

  config)
    echo "=== kube-proxy Config ==="
    kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' 2>/dev/null || echo "ConfigMap not found"
    echo ""
    echo "=== kube-proxy Pods ==="
    kubectl -n kube-system get pod -l k8s-app=kube-proxy -o wide
    ;;

  switch)
    NEW_MODE="${1:?Usage: $0 switch {iptables|ipvs}}"
    echo "=== Switching kube-proxy to ${NEW_MODE} mode ==="
    echo ""
    echo "Current mode:"
    kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' 2>/dev/null | grep mode || echo "unknown"
    echo ""
    echo "To switch:"
    echo "  1. kubectl -n kube-system edit configmap kube-proxy"
    echo "  2. Change: mode: \"${NEW_MODE}\""
    echo "  3. kubectl -n kube-system rollout restart ds kube-proxy"
    echo "  4. kubectl -n kube-system rollout status ds/kube-proxy --timeout=60s"
    echo ""
    echo "Or run:"
    if [ "${NEW_MODE}" = "ipvs" ]; then
      echo "  kubectl -n kube-system patch configmap kube-proxy --type=strategic \\"
      echo "    --patch='{\"data\":{\"config.conf\":\"apiVersion: kubeproxy.config.k8s.io/v1alpha1\\nkind: KubeProxyConfiguration\\nmode: ipvs\\nipvs:\\n  scheduler: rr\\n\"}}'"
    else
      echo "  kubectl -n kube-system edit configmap kube-proxy"
      echo "  # Change mode: ipvs → mode: iptables"
    fi
    echo "  kubectl -n kube-system rollout restart ds kube-proxy"
    ;;

  test)
    SVC_NAME="${1:?Usage: $0 test <service-name> [count]}"
    COUNT="${2:-10}"
    NAMESPACE="${3:-default}"
    SVC_IP=$(kubectl -n "${NAMESPACE}" get svc "${SVC_NAME}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [ -z "${SVC_IP}" ]; then
      echo "ERROR: Service not found: ${NAMESPACE}/${SVC_NAME}"
      exit 1
    fi
    echo "=== Test Service: ${SVC_NAME} (${SVC_IP}) ==="
    echo "Sending ${COUNT} requests..."
    echo ""
    for i in $(seq 1 "${COUNT}"); do
      kubectl exec client -- wget -qO- "http://${SVC_IP}" 2>/dev/null || echo "FAIL"
    done | sort | uniq -c | sort -rn
    ;;

  ipvs)
    echo "=== IPVS Virtual Servers ==="
    sudo ipvsadm -L -n 2>/dev/null || echo "ipvsadm not installed or IPVS not active"
    echo ""
    echo "=== IPVS Stats ==="
    sudo ipvsadm -L -n --stats 2>/dev/null || true
    echo ""
    echo "=== IPVS Modules ==="
    lsmod | grep ip_vs || echo "IPVS modules not loaded"
    ;;

  flush)
    echo "=== Flush conntrack ==="
    sudo conntrack -F
    echo "conntrack flushed"
    ;;

  *)
    echo "Usage: $0 {mode|services|trace-svc|trace-nodeport|conntrack|counters|config|switch|test|ipvs|flush}"
    echo ""
    echo "Examples:"
    echo "  $0 mode                                    # Show kube-proxy mode"
    echo "  $0 services                                 # List all Services + EndpointSlices"
    echo "  $0 trace-svc web-service                   # Trace iptables for Service"
    echo "  $0 trace-nodeport 30080                    # Trace NodePort iptables"
    echo "  $0 conntrack 10.96.0.1                     # Show conntrack for Service IP"
    echo "  $0 counters                                 # iptables packet counters"
    echo "  $0 config                                   # Show kube-proxy config"
    echo "  $0 switch ipvs                              # Instructions to switch to IPVS"
    echo "  $0 test web-service 30                      # Send 30 requests, count distribution"
    echo "  $0 ipvs                                     # Show IPVS virtual servers"
    echo "  $0 flush                                    # Flush conntrack table"
    exit 1
    ;;
esac
