# 06 — Encryption at Rest

## Encryption at Rest là gì

Mặc định, Kubernetes lưu **tất cả** resource trong etcd dạng protobuf (không mã hóa). Nếu attacker truy cập etcd data dir (`/var/lib/etcd/`) hoặc etcd endpoint, họ đọc được Secret, ConfigMap, và mọi resource.

**Encryption at rest** mã hóa resource trước khi ghi vào etcd — attacker đọc etcd raw chỉ thấy encrypted data.

```
Without encryption:
  kubectl create secret → API Server → etcd: <plaintext protobuf>
  etcdctl get /registry/secrets/default/db-password | strings
  # password123  ← readable!

With encryption:
  kubectl create secret → API Server → encrypt → etcd: <encrypted data>
  etcdctl get /registry/secrets/default/db-password | strings
  # k8s:enc:aes-gcm:v1:key1:<binary>  ← unreadable
```

## Cấu hình

### EncryptionConfiguration

```yaml
# /etc/kubernetes/encryption-provider.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - aesgcm:
      keys:
      - name: key1
        secret: <base64-encoded-32-byte-key>
  - identity: {}
```

| Field | Ý nghĩa |
|-------|---------|
| `resources` | Resource type cần mã hóa (thường `secrets`, có thể thêm `configmaps`) |
| `providers` | Danh sách encryption provider — thử theo thứ tự |
| `aesgcm` | AES-GCM encryption (recommend) |
| `aescbc` | AES-CBC encryption (legacy, slower) |
| `secretbox` | XSalsa20-Poly1305 (secretbox) |
| `identity` | No encryption — fallback (plaintext) |

### API Server flag

```bash
--encryption-provider-config=/etc/kubernetes/encryption-provider.yaml
```

> API Server đọc config khi start. Thay đổi config → restart API Server. (v1.29+ hỗ trợ hot-reload qua file watch.)

## Providers

### identity — no encryption

```yaml
providers:
- identity: {}
```

> `identity` = plaintext. Dùng làm fallback — resource không match provider nào sẽ không mã hóa. Nếu `identity` là provider đầu tiên → **không mã hóa gì** (mọi resource plaintext).

### aesgcm — AES-GCM (recommend)

```yaml
providers:
- aesgcm:
    keys:
    - name: key1
      secret: c2VjcmV0LWtleS0zMi1ieXRlcy1sb25nLWxvbmc=  # base64(32 bytes)
```

| Field | Ý nghĩa |
|-------|---------|
| `name` | Key name — ghi vào encrypted data prefix để biết key nào decrypt |
| `secret` | Base64-encoded 32-byte (256-bit) key |

> AES-GCM là **authenticated encryption** — detect tampering. **Recommend** cho production. Key phải 32 bytes (256-bit).

### aescbc — AES-CBC (legacy)

```yaml
providers:
- aescbc:
    keys:
    - name: key1
      secret: c2VjcmV0LWtleS0zMi1ieXRlcy1sb25nLWxvbmc=
```

> AES-CBC không có authentication — không detect tampering. Slower than AES-GCM. **Not recommend** — dùng `aesgcm` thay thế.

### secretbox — XSalsa20-Poly1305

```yaml
providers:
- secretbox:
    keys:
    - name: key1
      secret: <base64-encoded-32-byte-key>
```

> Secretbox dùng XSalsa20-Poly1305 — authenticated encryption. Pure Go implementation (không phụ thuộc kernel crypto). Good alternative nếu AES-NI không available.

## Provider order — quan trọng

Provider được thử **theo thứ tự** trong config. Provider đầu tiên dùng để **encrypt**. Khi **decrypt**, thử từng provider cho đến khi match.

```yaml
# Config 1: key2 encrypt mới, key1 vẫn decrypt data cũ
providers:
- aesgcm:
    keys:
    - name: key2                    ← key mới, dùng encrypt
      secret: <base64-key2>
    - name: key1                    ← key cũ, vẫn decrypt data cũ
      secret: <base64-key1>
- identity: {}
```

> Khi **rotate key**: thêm key mới lên đầu (encrypt mới), giữ key cũ bên dưới (decrypt data cũ). Sau khi tất cả data re-encrypt bằng key mới, xóa key cũ.

## Key rotation

### Bước 1: Thêm key mới

```yaml
# /etc/kubernetes/encryption-provider.yaml
resources:
- resources:
  - secrets
  providers:
  - aesgcm:
      keys:
      - name: key2                    ← NEW key (encrypt)
        secret: <base64-new-key>
      - name: key1                    ← OLD key (decrypt only)
        secret: <base64-old-key>
  - identity: {}
```

```bash
# Restart API Server (nếu không hot-reload)
sudo systemctl restart kubelet  # kubelet restart static pod
```

### Bước 2: Re-encrypt tất cả Secret

```bash
# Re-encrypt tất cả secret trong tất cả namespace
kubectl get secrets --all-namespaces -o json \
  | kubectl replace -f -
```

> `kubectl replace` force API Server read + write lại mỗi Secret. Read = decrypt bằng key cũ. Write = encrypt bằng key mới (key2 — provider đầu tiên).

### Bước 3: Xóa key cũ

Sau khi tất cả Secret đã re-encrypt bằng key mới, xóa key cũ:

```yaml
resources:
- resources:
  - secrets
  providers:
  - aesgcm:
      keys:
      - name: key2                    ← chỉ key mới
        secret: <base64-key2>
  - identity: {}
```

> **Quan trọng**: Không xóa key cũ trước khi re-encrypt xong — Secret chưa re-encrypt sẽ không decrypt được → mất data.

## Tạo encryption key

```bash
# Tạo 32-byte random key, base64 encode
head -c 32 /dev/urandom | base64
# c2VjcmV0LWtleS0zMi1ieXRlcy1sb25nLWxvbmc=
```

> Dùng `/dev/urandom` (không `/dev/random` — blocking). Key phải đúng 32 bytes (256-bit) cho AES-256.

## Verify encryption

### Tạo Secret

```bash
kubectl create secret generic test-secret \
  --from-literal=password=supersecret123 \
  -n default
```

### Đọc raw trong etcd

```bash
# Setup etcdctl env
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/healthcheck-client.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/healthcheck-client.key

# Đọc Secret raw
etcdctl get /registry/secrets/default/test-secret | strings
```

### Không có encryption:

```
test-secret
default
password
supersecret123       ← plaintext!
```

### Có encryption (AES-GCM):

```
k8s:enc:aes-gcm:v1:key1
<binary data>        ← encrypted, không đọc được
```

> Prefix `k8s:enc:aes-gcm:v1:key1` cho biết: encrypted bằng AES-GCM, version v1, key name `key1`.

## Disable encryption (revert to plaintext)

### Bước 1: Đặt identity lên đầu

```yaml
resources:
- resources:
  - secrets
  providers:
  - identity: {}                      ← identity first (encrypt = plaintext)
  - aesgcm:
      keys:
      - name: key1                    ← still decrypt old encrypted data
        secret: <base64-key>
```

### Bước 2: Re-encrypt tất cả Secret

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

> Lúc này, API Server read = decrypt bằng key1, write = "encrypt" bằng identity (plaintext). Secret mới ghi plaintext.

### Bước 3: Xóa encryption config

```bash
# Remove --encryption-provider-config flag
# Restart API Server
```

> **Không xóa config trước khi re-encrypt** — Secret chưa re-encrypt sẽ không decrypt được.

## Encryption prefix

Mỗi encrypted resource có prefix cho biết provider + key:

```
k8s:enc:<provider>:<version>:<key-name>:<encrypted-data>
```

| Provider | Prefix | Ví dụ |
|----------|--------|-------|
| AES-GCM | `k8s:enc:aes-gcm:v1:` | `k8s:enc:aes-gcm:v1:key1:<binary>` |
| AES-CBC | `k8s:enc:aes-cbc:v1:` | `k8s:enc:aes-cbc:v1:key1:<binary>` |
| Secretbox | `k8s:enc:secretbox:v1:` | `k8s:enc:secretbox:v1:key1:<binary>` |
| Identity | (no prefix) | `<plaintext protobuf>` |

> API Server đọc prefix để biết provider + key nào decrypt. Nếu prefix không match provider nào → error.

## Mã hóa resource khác ngoài Secret

Mặc định chỉ mã hóa Secret. Có thể mã hóa thêm resource:

```yaml
resources:
- resources:
  - secrets
  - configmaps
  - persistentvolumeclaims
  providers:
  - aesgcm:
      keys:
      - name: key1
        secret: <base64-key>
  - identity: {}
```

> **Cảnh báo**: Mã hóa nhiều resource type tăng CPU usage (mỗi read/write đều encrypt/decrypt). Production thường chỉ mã hóa Secret — Secret chứa nhạy cảm nhất (password, token, key).

## Performance impact

| Operation | Without encryption | With encryption |
|-----------|-------------------|-----------------|
| CREATE Secret | ~1ms | ~2ms (encrypt overhead) |
| GET Secret | ~1ms | ~2ms (decrypt overhead) |
| LIST Secret | ~5ms | ~10ms (decrypt each) |

> AES-GCM với AES-NI (hardware acceleration) overhead rất nhỏ (~1ms per operation). Không đáng kể trừ khi tạo/đọc hàng nghìn Secret per second.

## Security considerations

| Threat | Encryption at rest giúp? |
|--------|------------------------|
| Attacker đọc etcd data dir (`/var/lib/etcd/`) | **Yes** — data encrypted |
| Attacker truy cập etcd endpoint (port 2379) | **Yes** — data encrypted |
| Attacker có API Server access (kubectl) | **No** — API Server decrypt trước khi trả về |
| Attacker có kubelet access | **No** — kubelet gọi API Server, API Server decrypt |
| Attacker có etcd backup file | **Yes** — backup chứa encrypted data |
| Attacker có encryption key + etcd data | **No** — có key = decrypt được |

> Encryption at rest bảo vệ khi attacker truy cập **etcd data** nhưng **không có API Server access**. Nếu attacker có API Server access (kubectl), encryption không giúp gì — API Server decrypt transparently.

## Best practices

- Dùng **AES-GCM** (authenticated encryption, hardware accelerated).
- **Rotate key** định kỳ (3-6 tháng) — thêm key mới, re-encrypt, xóa key cũ.
- **Backup encryption key** — mất key = mất data (không decrypt được).
- **Không commit key vào git** — lưu trong secret manager (Vault, AWS KMS, GCP KMS).
- Chỉ mã hóa **Secret** (trừ khi có requirement mã hóa thêm resource).
- `identity: {}` luôn ở cuối — fallback cho resource không match provider nào.
- **Test restore** — restore etcd backup + encryption key, verify decrypt thành công.

## Liên hệ với Kubernetes

- Encryption at rest mã hóa resource **trong etcd** — không mã hóa in transit (TLS đã lo).
- Mặc định **KHÔNG mã hóa** — phải enable qua `--encryption-provider-config`.
- AES-GCM là provider recommend — authenticated encryption, hardware accelerated.
- Key rotation: thêm key mới → re-encrypt → xóa key cũ. Không xóa key cũ trước khi re-encrypt.
- Encryption at rest **không bảo vệ** khi attacker có API Server access — API Server decrypt transparently.
- Mã hóa nhiều resource type tăng CPU overhead — production thường chỉ mã hóa Secret.
- `identity: {}` ở cuối config — fallback cho resource không match provider nào.
