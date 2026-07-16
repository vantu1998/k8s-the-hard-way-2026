# Exercise 05 — Script sinh toàn bộ cert cho cluster 3 master + 2 worker bằng cfssl

> **Mục tiêu**: Viết script hoàn chỉnh sinh tất cả cert cho cluster HA (3 master + 2 worker) bằng cfssl, verify tất cả.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Đã làm Exercise 01-04, `cfssl`, `cfssljson`, `openssl`, `jq`

## Bối cảnh

Khi làm Kubernetes the hard way, cần sinh **tất cả cert** trước khi bootstrap cluster. Script này tự động hóa toàn bộ bằng cfssl — chỉ cần khai báo node IP.

## Bước 1: Khai báo cluster info

```bash
cd /tmp/k8s-certs

# Cluster configuration
MASTER1_IP="10.0.0.1"
MASTER2_IP="10.0.0.2"
MASTER3_IP="10.0.0.3"
WORKER1_IP="10.0.0.4"
WORKER2_IP="10.0.0.5"
K8S_SERVICE_IP="10.96.0.1"
DNS_DOMAIN="cluster.local"
LB_IP=""           # Load balancer IP (nếu có)
LB_DOMAIN=""       # Load balancer domain (nếu có, ví dụ k8s-api.example.com)
```

## Bước 2: Viết script gen-all-certs.sh

```bash
cat > gen-all-certs.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail

# ============================================================
# Kubernetes Certificate Generator (cfssl)
# Cluster: 3 master + 2 worker
# ============================================================

# Cluster configuration
MASTER1_IP="${MASTER1_IP:-10.0.0.1}"
MASTER2_IP="${MASTER2_IP:-10.0.0.2}"
MASTER3_IP="${MASTER3_IP:-10.0.0.3}"
WORKER1_IP="${WORKER1_IP:-10.0.0.4}"
WORKER2_IP="${WORKER2_IP:-10.0.0.5}"
K8S_SERVICE_IP="${K8S_SERVICE_IP:-10.96.0.1}"
DNS_DOMAIN="${DNS_DOMAIN:-cluster.local}"
LB_IP="${LB_IP:-}"
LB_DOMAIN="${LB_DOMAIN:-}"

CERT_DIR="${CERT_DIR:-./certs}"
DAYS_H="8760h"
CA_DAYS_H="87600h"

mkdir -p "${CERT_DIR}"

echo "=== Kubernetes Certificate Generator (cfssl) ==="
echo "  Masters: ${MASTER1_IP}, ${MASTER2_IP}, ${MASTER3_IP}"
echo "  Workers: ${WORKER1_IP}, ${WORKER2_IP}"
echo "  Service IP: ${K8S_SERVICE_IP}"
echo "  Load Balancer: ${LB_IP:-none}${LB_DOMAIN:+ (${LB_DOMAIN})}"
echo "  Output: ${CERT_DIR}"
echo ""

# --- Helper functions ---

gen_ca() {
    local name=$1 cn=$2
    cat > "${CERT_DIR}/${name}-csr.json" << EOF
{
  "CN": "${cn}",
  "key": {"algo": "rsa", "size": 2048},
  "names": [{"CN": "${cn}"}],
  "ca": {"expiry": "${CA_DAYS_H}"}
}
EOF
    cfssl gencert -initca "${CERT_DIR}/${name}-csr.json" | cfssljson -bare "${CERT_DIR}/${name}"
    echo "  ✓ ${name}.pem (${cn})"
}

gen_cert() {
    local name=$1 cn=$2 ca_name=$3 profile=$4 hosts=$5 names=$6
    cat > "${CERT_DIR}/${name}-csr.json" << EOF
{
  "CN": "${cn}",
  "hosts": ${hosts},
  "key": {"algo": "rsa", "size": 2048},
  "names": ${names}
}
EOF
    cfssl gencert \
        -ca="${CERT_DIR}/${ca_name}.pem" \
        -ca-key="${CERT_DIR}/${ca_name}-key.pem" \
        -config="${CERT_DIR}/ca-config.json" \
        -profile="${profile}" \
        "${CERT_DIR}/${name}-csr.json" | cfssljson -bare "${CERT_DIR}/${name}"
}

verify_cert() {
    local name=$1 ca_name=$2
    if openssl verify -CAfile "${CERT_DIR}/${ca_name}.pem" "${CERT_DIR}/${name}.pem" >/dev/null 2>&1; then
        echo "  ✓ ${name}.pem"
    else
        echo "  ✗ ${name}.pem FAILED"
        exit 1
    fi
}

# --- 0. ca-config.json (signing config) ---

cat > "${CERT_DIR}/ca-config.json" << 'EOF'
{
  "signing": {
    "default": {
      "expiry": "8760h",
      "usages": ["signing", "key encipherment", "server auth"]
    },
    "profiles": {
      "server": {
        "expiry": "8760h",
        "usages": ["signing", "key encipherment", "server auth"]
      },
      "client": {
        "expiry": "8760h",
        "usages": ["signing", "key encipherment", "client auth"]
      },
      "peer": {
        "expiry": "8760h",
        "usages": ["signing", "key encipherment", "server auth", "client auth"]
      }
    }
  }
}
EOF

# --- 1. CAs ---

echo "--- Creating CAs ---"

gen_ca ca "kubernetes-ca"
gen_ca etcd-ca "etcd-ca"
gen_ca front-proxy-ca "kubernetes-front-proxy-ca"

# Service account key pair (not a cert)
openssl genrsa -out "${CERT_DIR}/sa.key" 2048 2>/dev/null
openssl rsa -in "${CERT_DIR}/sa.key" -pubout -out "${CERT_DIR}/sa.pub" 2>/dev/null
echo "  ✓ sa.key + sa.pub"

# --- 2. kube-apiserver ---

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
echo "  Total: $(ls ${CERT_DIR}/*.pem 2>/dev/null | wc -l) PEM files"
echo "  Location: ${CERT_DIR}"
echo ""
echo "  IMPORTANT: Secure all *-key.pem files! CA keys compromised = cluster compromised."
SCRIPT

chmod +x gen-all-certs.sh
```

## Bước 3: Chạy script

```bash
# Chạy với default config
./gen-all-certs.sh

# Hoặc custom (có load balancer)
MASTER1_IP=192.168.1.10 MASTER2_IP=192.168.1.11 MASTER3_IP=192.168.1.12 \
WORKER1_IP=192.168.1.20 WORKER2_IP=192.168.1.21 \
K8S_SERVICE_IP=10.96.0.1 \
LB_IP=192.168.1.100 LB_DOMAIN=k8s-api.example.com \
./gen-all-certs.sh
```

Output:

```text
=== Kubernetes Certificate Generator (cfssl) ===
  Masters: 10.0.0.1, 10.0.0.2, 10.0.0.3
  Workers: 10.0.0.4, 10.0.0.5
  Service IP: 10.96.0.1
  Load Balancer: none
  Output: ./certs

--- Creating CAs ---
  ✓ ca.pem (kubernetes-ca)
  ✓ etcd-ca.pem (etcd-ca)
  ✓ front-proxy-ca.pem (kubernetes-front-proxy-ca)
  ✓ sa.key + sa.pub

--- kube-apiserver ---
  ✓ apiserver.pem
  ✓ apiserver-etcd-client.pem
  ✓ apiserver-kubelet-client.pem

--- etcd ---
  ✓ etcd-server-1.pem
  ✓ etcd-peer-1.pem
  ✓ etcd-server-2.pem
  ✓ etcd-peer-2.pem
  ✓ etcd-server-3.pem
  ✓ etcd-peer-3.pem
  ✓ etcd-healthcheck-client.pem

--- scheduler + controller-manager ---
  ✓ scheduler.pem
  ✓ controller-manager.pem

--- admin ---
  ✓ admin.pem

--- front-proxy ---
  ✓ front-proxy-client.pem

--- kubelet ---
  ✓ kubelet-master-1.pem
  ✓ kubelet-master-2.pem
  ✓ kubelet-master-3.pem
  ✓ kubelet-worker-1.pem
  ✓ kubelet-worker-2.pem

=== Done! ===
  Total: 42 PEM files
```

**Kiểm tra**: Tất cả cert verify ✓, 42 PEM files.

## Bước 4: Verify tất cả cert

```bash
cd certs

# Cert ký bởi kubernetes CA
for cert in apiserver apiserver-kubelet-client scheduler controller-manager admin \
            kubelet-master-1 kubelet-master-2 kubelet-master-3 \
            kubelet-worker-1 kubelet-worker-2; do
    openssl verify -CAfile ca.pem ${cert}.pem
done

# Cert ký bởi etcd CA
for cert in apiserver-etcd-client etcd-server-1 etcd-peer-1 etcd-server-2 etcd-peer-2 \
            etcd-server-3 etcd-peer-3 etcd-healthcheck-client; do
    openssl verify -CAfile etcd-ca.pem ${cert}.pem
done

# Cert ký bởi front-proxy CA
openssl verify -CAfile front-proxy-ca.pem front-proxy-client.pem
```

**Kiểm tra**: Tất cả verify OK.

## Bước 5: Kiểm tra SAN quan trọng

```bash
# Apiserver SAN
cfssl certinfo -cert apiserver.pem | jq '.certificates[0].subject_alt_name'
# {
#   "DNS_names": ["kubernetes", "kubernetes.default", "kubernetes.default.svc",
#                 "kubernetes.default.svc.cluster.local", "localhost"],
#   "IP_addresses": ["10.96.0.1", "10.0.0.1", "10.0.0.2", "10.0.0.3", "127.0.0.1"]
#   # Nếu có LB_IP/LB_DOMAIN sẽ xuất hiện thêm trong DNS_names/IP_addresses
# }

# Etcd peer SAN
cfssl certinfo -cert etcd-peer-1.pem | jq '.certificates[0].subject_alt_name'
# {
#   "DNS_names": ["etcd-1", "localhost"],
#   "IP_addresses": ["10.0.0.1", "127.0.0.1"]
# }

# Kubelet SAN
cfssl certinfo -cert kubelet-master-1.pem | jq '.certificates[0].subject_alt_name'
# {
#   "DNS_names": ["master-1"],
#   "IP_addresses": ["10.0.0.1"]
# }
```

**Kiểm tra**: SAN đầy đủ — apiserver có tất cả master IP + service IP + DNS names.

## Bước 6: Kiểm tra usages

```bash
# Apiserver — server auth
cfssl certinfo -cert apiserver.pem | jq '.certificates[0].usages'
# ["Digital Signature", "Key Encipherment", "Server Auth"]

# Admin — client auth
cfssl certinfo -cert admin.pem | jq '.certificates[0].usages'
# ["Digital Signature", "Key Encipherment", "Client Auth"]

# Etcd peer — cả 2 (mTLS)
cfssl certinfo -cert etcd-peer-1.pem | jq '.certificates[0].usages'
# ["Digital Signature", "Key Encipherment", "Server Auth", "Client Auth"]
```

**Kiểm tra**: Usages đúng theo profile — server, client, peer.

## Bước 7: Kiểm tra expiry

```bash
# CA — 10 năm
cfssl certinfo -cert ca.pem | jq '{not_before, not_after}'
# not_after = 10 năm từ now

# Component cert — 1 năm
for cert in apiserver admin scheduler controller-manager kubelet-master-1; do
    echo -n "$cert: "
    openssl x509 -in ${cert}.pem -noout -enddate
done
# apiserver: notAfter=... (1 năm)
# ...
```

**Kiểm tra**: CA valid 10 năm, component cert valid 1 năm.

## Cleanup

```bash
cd /tmp
rm -rf k8s-certs
```

## Câu hỏi tự kiểm tra

1. Tổng cộng cần bao nhiêu cert cho cluster 3 master + 2 worker?
2. Script dùng cfssl `profile=peer` cho kubelet — tại sao không dùng `profile=server`?
3. Nếu thêm master thứ 4 — cần tạo thêm cert nào? Cần re-sign cert nào?
4. cfssl `hosts` array so với openssl `-extfile` — lợi ích gì?
5. CA cert valid 10 năm, component cert valid 1 năm — tại sao?

## Đáp án tham khảo

1. 3 CA + 1 SA key pair + 3 apiserver cert + 6 etcd cert (3 server + 3 peer) + 1 etcd healthcheck + 2 control plane + 1 admin + 1 front-proxy + 5 kubelet = ~22 cert + 3 CA + SA key = ~28 PEM (cert+key = ~56 files).
2. Kubelet vừa là server (apiserver → kubelet) vừa là client (kubelet → apiserver). Profile `peer` có cả `serverAuth` + `clientAuth`. Profile `server` chỉ có `serverAuth`.
3. Etcd server + peer cert cho master-4, kubelet cert cho master-4, **re-sign apiserver cert** (thêm IP master-4 vào `hosts` array).
4. cfssl `hosts` tự nhận DNS vs IP, tự copy SAN vào cert. openssl `-extfile` phải khai báo SAN 2 lần (CSR + extfile), phải prefix `DNS:`/`IP:` rõ ràng — dễ quên → cert thiếu SAN.
5. CA ổn định lâu (10 năm) — rotation CA rất khó. Component cert rotate thường (1 năm) — giảm rủi ro nếu key bị lộ.
