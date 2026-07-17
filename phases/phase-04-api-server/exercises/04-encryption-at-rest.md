# Exercise 04 — Encryption at Rest

> **Mục tiêu**: Enable encryption at rest, tạo Secret, đọc raw trong etcd — thấy đã mã hóa. Key rotation.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Kubernetes cluster đang chạy (kubeadm hoặc exercise 01), etcdctl access, API Server admin access

## Bối cảnh

Mặc định Secret trong etcd lưu plaintext. Bài này enable encryption at rest, verify Secret mã hóa trong etcd, thực hành key rotation.

## Bước 1: Kiểm tra encryption đang tắt

```bash
# Tạo Secret
kubectl create secret generic test-secret \
  --from-literal=password=supersecret123 \
  -n default

# Đọc raw trong etcd
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/healthcheck-client.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/healthcheck-client.key

etcdctl get /registry/secrets/default/test-secret | strings
# test-secret
# default
# password
# supersecret123       ← plaintext! Không mã hóa!
```

> Nếu thấy `supersecret123` → encryption đang tắt. Nếu thấy `k8s:enc:aes-gcm:...` → encryption đang bật.

**Kiểm tra**: `strings` output chứa `supersecret123` — xác nhận encryption tắt.

## Bước 2: Tạo encryption key

```bash
# Tạo 32-byte random key, base64 encode
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
echo "${ENCRYPTION_KEY}"
# c2VjcmV0LWtleS0zMi1ieXRlcy1sb25nLWxvbmc=

# Lưu key — QUAN TRỌNG: mất key = mất data
echo "${ENCRYPTION_KEY}" > /tmp/encryption-key.txt
```

> **Backup key** ở nơi an toàn (password manager, Vault). Mất key = không decrypt được Secret cũ.

## Bước 3: Tạo EncryptionConfiguration

```bash
sudo mkdir -p /etc/kubernetes

sudo tee /etc/kubernetes/encryption-provider.yaml > /dev/null << EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - aesgcm:
      keys:
      - name: key1
        secret: ${ENCRYPTION_KEY}
  - identity: {}
EOF

# Verify
cat /etc/kubernetes/encryption-provider.yaml
```

> `aesgcm` là provider đầu tiên → encrypt mới bằng key1. `identity` ở cuối → fallback cho resource không match.

**Kiểm tra**: File tồn tại, chứa `aesgcm` + key1 + `identity`.

## Bước 4: Enable encryption trên API Server

### Nếu chạy standalone (exercise 01):

Stop API Server, thêm flag `--encryption-provider-config`, restart:

```bash
# Stop
sudo kill $(pgrep kube-apiserver)

# Restart với encryption flag
sudo kube-apiserver \
  --etcd-servers=https://127.0.0.1:2379 \
  --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt \
  --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt \
  --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key \
  --client-ca-file=/etc/kubernetes/pki/ca.crt \
  --tls-cert-file=/etc/kubernetes/pki/apiserver.crt \
  --tls-private-key-file=/etc/kubernetes/pki/apiserver.key \
  --service-account-key-file=/etc/kubernetes/pki/sa.pub \
  --service-account-signing-key-file=/etc/kubernetes/pki/sa.key \
  --service-account-issuer=https://kubernetes.default.svc.cluster.local \
  --service-cluster-ip-range=10.96.0.0/12 \
  --authorization-mode=Node,RBAC \
  --enable-admission-plugins=NodeRestriction,ServiceAccount \
  --anonymous-auth=false \
  --bind-address=0.0.0.0 \
  --secure-port=6443 \
  --allow-privileged=true \
  --encryption-provider-config=/etc/kubernetes/encryption-provider.yaml \
  --v=2 &
```

### Nếu chạy kubeadm (static pod):

```bash
# Edit kube-apiserver manifest
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml

# Thêm vào command list:
#   - --encryption-provider-config=/etc/kubernetes/encryption-provider.yaml

# Thêm volumeMount + volume cho encryption-provider.yaml:
#   volumeMounts:
#   - mountPath: /etc/kubernetes/encryption-provider.yaml
#     name: encryption-provider
#     readOnly: true
#   volumes:
#   - hostPath:
#       path: /etc/kubernetes/encryption-provider.yaml
#       type: FileOrCreate
#     name: encryption-provider

# Kubelet tự restart static pod khi manifest thay đổi
```

**Kiểm tra**: `curl -k https://127.0.0.1:6443/healthz` trả về `ok` sau restart.

## Bước 5: Verify — Secret mới được mã hóa

```bash
# Xóa Secret cũ (tạo khi chưa encryption)
kubectl delete secret test-secret -n default

# Tạo Secret mới (sau encryption)
kubectl create secret generic test-secret \
  --from-literal=password=supersecret123 \
  -n default

# Đọc raw trong etcd
etcdctl get /registry/secrets/default/test-secret | strings
# k8s:enc:aes-gcm:v1:key1
# <binary data>        ← encrypted! Không thấy supersecret123
```

> Prefix `k8s:enc:aes-gcm:v1:key1` xác nhận: encrypted bằng AES-GCM, key name `key1`.

**Kiểm tra**: `strings` output chứa `k8s:enc:aes-gcm:v1:key1`, **không** chứa `supersecret123`.

## Bước 6: Verify — kubectl vẫn đọc được

```bash
# kubectl decrypt tự động
kubectl get secret test-secret -n default -o jsonpath='{.data.password}' | base64 -d
# supersecret123

# Describe
kubectl describe secret test-secret -n default
# Name:         test-secret
# Namespace:    default
# Type:         Opaque
# Data
# ====
# password: 13 bytes
```

> API Server decrypt transparently — kubectl không biết Secret đã mã hóa. Encryption at rest **không ảnh hưởng** client.

**Kiểm tra**: `kubectl get secret` trả về `supersecret123` — decrypt thành công.

## Bước 7: Re-encrypt Secret cũ

Secret tạo **trước** khi enable encryption vẫn còn plaintext. Re-encrypt:

```bash
# Tạo Secret cũ (plaintext) — simulate trước encryption
# (Nếu đã xóa ở bước 5, tạo lại rồi disable encryption temporarily để simulate)
# Skip nếu không có Secret cũ

# Re-encrypt tất cả Secret
kubectl get secrets --all-namespaces -o json | kubectl replace -f -

# Verify — tất cả Secret giờ đều encrypted
etcdctl get --prefix /registry/secrets/ --keys-only
# /registry/secrets/default/test-secret
# /registry/secrets/kube-system/...

# Check mỗi Secret
etcdctl get /registry/secrets/default/test-secret | strings | head -1
# k8s:enc:aes-gcm:v1:key1    ← encrypted
```

> `kubectl replace` force API Server read (decrypt bằng identity = plaintext) + write (encrypt bằng aesgcm = key1).

## Bước 8: Key rotation

### 8a. Tạo key mới

```bash
# Tạo key mới
ENCRYPTION_KEY2=$(head -c 32 /dev/urandom | base64)
echo "${ENCRYPTION_KEY2}" >> /tmp/encryption-key.txt

# Update config — key2 lên đầu (encrypt mới), key1 giữ lại (decrypt cũ)
sudo tee /etc/kubernetes/encryption-provider.yaml > /dev/null << EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - aesgcm:
      keys:
      - name: key2
        secret: ${ENCRYPTION_KEY2}
      - name: key1
        secret: $(head -1 /tmp/encryption-key.txt)
  - identity: {}
EOF
```

### 8b. Restart API Server

```bash
# Standalone
sudo kill $(pgrep kube-apiserver)
# Restart với cùng command (config file đã update)

# kubeadm — kubelet tự restart khi manifest thay đổi (nếu dùng file watch)
# Hoặc: sudo systemctl restart kubelet
```

### 8c. Re-encrypt tất cả Secret bằng key mới

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

### 8d. Verify — Secret giờ encrypt bằng key2

```bash
etcdctl get /registry/secrets/default/test-secret | strings | head -1
# k8s:enc:aes-gcm:v1:key2    ← key2 now
```

### 8e. Xóa key cũ

```bash
# Sau khi tất cả Secret đã re-encrypt bằng key2, xóa key1
sudo tee /etc/kubernetes/encryption-provider.yaml > /dev/null << EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - aesgcm:
      keys:
      - name: key2
        secret: ${ENCRYPTION_KEY2}
  - identity: {}
EOF

# Restart API Server
```

> **Quan trọng**: Không xóa key1 trước khi re-encrypt xong — Secret chưa re-encrypt bằng key2 sẽ không decrypt được (key1 đã bị xóa).

**Kiểm tra**: `etcdctl get` cho thấy prefix `k8s:enc:aes-gcm:v1:key2`.

## Bước 9: Disable encryption (revert)

```bash
# Đặt identity lên đầu (encrypt = plaintext)
sudo tee /etc/kubernetes/encryption-provider.yaml > /dev/null << EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - identity: {}
  - aesgcm:
      keys:
      - name: key2
        secret: ${ENCRYPTION_KEY2}
EOF

# Restart API Server

# Re-encrypt — read bằng key2, write bằng identity (plaintext)
kubectl get secrets --all-namespaces -o json | kubectl replace -f -

# Verify — plaintext again
etcdctl get /registry/secrets/default/test-secret | strings
# test-secret
# password
# supersecret123       ← plaintext again

# Xóa encryption config flag, restart API Server
```

## Câu hỏi tự kiểm tra

1. Tại sao Secret tạo trước khi enable encryption vẫn còn plaintext?
2. `identity: {}` ở cuối config có vai trò gì? Nếu bỏ có sao không?
3. Key rotation: tại sao phải re-encrypt trước khi xóa key cũ?
4. Encryption at rest bảo vệ gì? Không bảo vệ gì?
5. Tại sao `kubectl get secret` vẫn đọc được sau khi encryption — API Server làm gì?

## Đáp án tham khảo

1. Encryption chỉ áp dụng cho **write mới**. Secret tạo trước = đã ghi plaintext vào etcd. API Server đọc plaintext, không cần decrypt. Re-encrypt (`kubectl replace`) để mã hóa Secret cũ.
2. `identity` = fallback cho resource không match provider nào. Nếu bỏ, resource không mã hóa (như Secret tạo trước encryption) sẽ không decrypt được — API Server không biết dùng provider nào.
3. Nếu xóa key cũ trước re-encrypt, Secret chưa re-encrypt vẫn encrypt bằng key cũ → không decrypt được → mất data. Re-encrypt trước = tất cả Secret chuyển sang key mới → an toàn xóa key cũ.
4. Bảo vệ: attacker đọc etcd data dir / etcd endpoint / etcd backup. Không bảo vệ: attacker có API Server access (kubectl) — API Server decrypt transparently.
5. API Server decrypt tự động khi đọc từ etcd. Client (kubectl) nhận JSON đã decrypt — không biết Secret đã mã hóa. Encryption at rest transparent với client.
