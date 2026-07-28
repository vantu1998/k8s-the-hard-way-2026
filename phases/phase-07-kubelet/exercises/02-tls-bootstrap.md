# Exercise 02 — TLS Bootstrap

> **Mục tiêu**: Join worker node vào cluster bằng TLS bootstrap token, xem CSR trong `kubectl get csr`, approve CSR, verify node joined.
>
> **Thời gian dự kiến**: 40 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 4), VM mới cho worker node, `kubeadm` installed trên worker

## Bối cảnh

TLS Bootstrap cho phép worker node join cluster không cần cert sẵn. Bài này tạo bootstrap token, join worker node, quan sát CSR flow, verify node joined.

## Prerequisites

```bash
# Trên master — cluster running
kubectl get nodes
# NAME      STATUS   ROLES           AGE   VERSION
# master    Ready     control-plane   10d   v1.33.0

# Trên worker VM — kubeadm, kubelet, containerd installed
# (chưa join cluster, chưa có cert)
```

## Bước 1: Tạo bootstrap token (trên master)

```bash
# Tạo token
kubeadm token create --print-join-command
# kubeadm join 192.168.1.10:6443 --token abcdef.0123456789abcdef \
#   --discovery-token-ca-cert-hash sha256:xxx123

# Lưu token + hash
TOKEN="abcdef.0123456789abcdef"
CA_HASH="sha256:xxx123"
API_SERVER="https://192.168.1.10:6443"
```

```bash
# Verify token
kubectl get secret -n kube-system bootstrap-token-abcdef
# NAME                       TYPE                            DATA   AGE
# bootstrap-token-abcdef     bootstrap.kubernetes.io/token   6      10s

# List tokens
kubeadm token list
# TOKEN                     TTL   EXPIRES   USAGES                   DESCRIPTION
# abcdef.0123456789abcdef   23h   ...       authentication,signing   ...
```

**Kiểm tra**: Bootstrap token tạo thành công, Secret tồn tại trong `kube-system`.

## Bước 2: Verify RBAC cho auto-approve

```bash
# Check auto-approve ClusterRoleBinding
kubectl get clusterrolebinding | grep autoapprove
# kubeadm:node-autoapprove-bootstrap             ClusterRole/...
# kubeadm:node-autoapprove-certificate-rotation  ClusterRole/...

# If missing, create:
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubeadm:node-autoapprove-bootstrap
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:nodecluster
subjects:
- kind: Group
  name: system:bootstrappers
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubeadm:node-autoapprove-certificate-rotation
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:selfnodeclient
subjects:
- kind: Group
  name: system:nodes
  apiGroup: rbac.authorization.k8s.io
EOF
```

**Kiểm tra**: 2 ClusterRoleBinding `autoapprove` tồn tại.

## Bước 3: Join worker node (trên worker VM)

```bash
# SSH vào worker VM
ssh worker-2

# Join cluster
sudo kubeadm join 192.168.1.10:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:xxx123

# Output:
# [preflight] Running pre-flight checks
# [preflight] Pulling images required for setting up a Kubernetes cluster
# [preflight] This might take a minute or two
# [preflight] You can also perform this action on beforehand with 'kubeadm config images pull'
# [kubelet-start] Writing kubelet environment file with flags to file "/var/lib/kubelet/kubeadm-flags.env"
# [kubelet-start] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
# [kubelet-start] Starting the kubelet
# [kubelet-start] Waiting for the kubelet to perform the TLS Bootstrap...
# [kubelet-start] Pulled tlsBootstrapClientConfig
# [kubelet-start] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
# [kubelet-start] Writing kubelet environment file with flags to file "/var/lib/kubelet/kubeadm-flags.env"
# [kubelet-start] Starting the kubelet
# [kubelet-start] Successfully started the kubelet
# This node has joined the cluster:
# * Certificate signing request was sent to apiserver for approval
# * The Kubelet was informed of the new secure connection details
# * The control-plane indicated that a final bootstrap was needed
# To start using your cluster, you need to run the following as a regular user:
#   mkdir -p $HOME/.kube
#   sudo cp -i /etc/kubernetes/kubelet.conf $HOME/.kube/config
#   sudo chown $(id -u):$(id -g) $HOME/.kube/config
# Run 'kubectl get nodes' on the control-plane to see this node join the cluster.
```

> kubeadm join flow:
> 1. Download CA cert (verify with hash)
> 2. Create bootstrap-kubelet.conf (token auth)
> 3. Start kubelet with bootstrap config
> 4. Kubelet submit CSR → auto-approve → receive cert
> 5. Kubelet create kubelet.conf (cert auth)
> 6. Kubelet register node

**Kiểm tra**: `kubeadm join` success, "This node has joined the cluster".

## Bước 4: Quan sát CSR (trên master)

```bash
# List CSR
kubectl get csr
# NAME        AGE   SIGNOR           REQUESTOR          REQUESTEDDURATION   CONDITION
# csr-abc123  30s   kubernetes-ca    kubelet-bootstrap  365d                Approved,Issued
# csr-def456  30s   kubernetes-ca    worker-2           365d                Approved,Issued

# CSR detail
kubectl get csr csr-abc123 -o yaml | grep -A 5 "spec:"
# spec:
#   request: LS0tLS1... (base64 CSR)
#   signerName: kubernetes.io/kube-apiserver-client-kubelet
#   usages:
#   - digital signature
#   - key encipherment
#   - client auth
#   username: kubelet-bootstrap
#   groups: system:bootstrappers
```

> 2 CSR: bootstrap CSR (kubelet-bootstrap, group system:bootstrappers) + client CSR (worker-2, group system:nodes). Cả 2 auto-approve + sign.

**Kiểm tra**: CSR `Approved,Issued` — auto-approve works.

## Bước 5: Verify node joined

```bash
# Trên master
kubectl get nodes
# NAME       STATUS   ROLES           AGE   VERSION
# master     Ready     control-plane   10d   v1.33.0
# worker-2   Ready     <none>          30s   v1.33.0   ← just joined!

# Check node detail
kubectl describe node worker-2 | head -20
# Name:               worker-2
# Roles:              <none>
# Labels:             beta.kubernetes.io/arch=amd64
#                     beta.kubernetes.io/os=linux
#                     kubernetes.io/hostname=worker-2
# ...
# Conditions:
#   Ready     True    Kubelet is posting ready status
```

**Kiểm tra**: Node `worker-2` Ready, joined cluster.

## Bước 6: Verify kubelet cert

```bash
# Trên worker-2 — check kubelet.conf (cert auth)
ssh worker-2 'cat /etc/kubernetes/kubelet.conf | grep client-certificate'
# client-certificate: /var/lib/kubelet/pki/kubelet-client-current.pem
# client-key: /var/lib/kubelet/pki/kubelet-client-current.pem

# Check cert
ssh worker-2 'openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject -issuer -dates'
# subject=O=system:nodes, CN=system:node:worker-2
# issuer=CN=kubernetes
# notBefore=Jan  1 00:00:00 2026 GMT
# notAfter=Jan  1 00:00:00 2027 GMT   ← valid 1 year
```

> Kubelet cert: `CN=system:node:worker-2`, `O=system:nodes`. Issued by Kubernetes CA. Valid 1 year. `rotateCertificates: true` → auto-rotate trước expire.

**Kiểm tra**: Kubelet cert valid, `CN=system:node:worker-2`, issuer = Kubernetes CA.

## Bước 7: Test cert rotation

```bash
# Check rotation config
ssh worker-2 'cat /var/lib/kubelet/config.yaml | grep rotateCertificates'
# rotateCertificates: true

# Kubelet auto-rotate khi cert còn 30% lifetime
# (~109 days before expire for 1-year cert)

# Manual check — list CSR for rotation
kubectl get csr | grep worker-2
# (initial CSR only — rotation CSR will appear ~109 days before expire)
```

> Cert rotation tự động — kubelet submit CSR mới khi cert còn 30% lifetime. Controller Manager auto-approve (system:nodes group). No restart needed.

## Bước 8: Manual CSR approve (if auto-approve fails)

```bash
# If CSR stuck Pending
kubectl get csr
# NAME        AGE   SIGNOR   REQUESTOR          CONDITION
# csr-xyz789  10s   <none>   kubelet-bootstrap  Pending

# Approve manually
kubectl certificate approve csr-xyz789
# certificatesigningrequest.certificates.k8s.io/csr-xyz789 approved

# Verify
kubectl get csr csr-xyz789
# NAME        AGE   SIGNOR           REQUESTOR          CONDITION
# csr-xyz789  15s   kubernetes-ca    kubelet-bootstrap  Approved,Issued
```

## Cleanup

```bash
# If you want to remove worker-2 from cluster
kubectl drain worker-2 --ignore-daemonsets --delete-emptydir-data --force
kubectl delete node worker-2

# On worker-2 — reset kubeadm
ssh worker-2 'sudo kubeadm reset'
```

## Câu hỏi tự kiểm tra

1. TLS Bootstrap giải quyết vấn đề gì? Tại sao không copy cert manually?
2. Bootstrap token format gì? Token ở đâu trong cluster?
3. CSR flow: kubelet submit CSR → ai approve? Ai sign?
4. `rotateCertificates: true` — khi nào kubelet rotate cert? Cần restart?
5. CA cert hash (`--discovery-token-ca-cert-hash`) có mục đích gì?

## Đáp án tham khảo

1. TLS Bootstrap giải quyết **chicken-and-egg**: worker node cần cert để connect API Server, nhưng cần API Server để nhận cert. Bootstrap token + CSR = secure auto-join. Không copy cert manually — insecure (cert leak), không scale (n worker = n cert copy), không rotation.
2. Token format: `ID.Secret` (6.16 char). Token stored trong Secret `kube-system/bootstrap-token-<ID>`. Token có TTL (default 24h kubeadm). Token auth → `system:bootstrappers` group → auto-approve CSR.
3. Kubelet submit CSR → Controller Manager **auto-approve** (CSR approver, check group `system:bootstrappers`/`system:nodes`) → Controller Manager **sign** (CSR signer, sign with CA key) → kubelet download cert. Cả approve + sign trong Controller Manager.
4. Kubelet rotate khi cert còn **30% lifetime** (~109 ngày trước expire cho cert 1 năm). Kubelet submit CSR mới → auto-approve → download new cert → **reload, no restart**. `rotateCertificates: true` trong kubelet config.
5. CA cert hash = verify API Server cert (tránh MITM attack). Kubelet download CA cert từ API Server, compare hash. Nếu hash không match → kubelet refuse connect. Attacker không thể fake API Server vì không có CA key.
