# Exercise 01 — Chạy kube-apiserver HA (3 nodes)

> **Mục tiêu**: Chạy `kube-apiserver` ở chế độ High Availability (HA) trên cả 3 master node, kết nối đến etcd cluster (3 nodes).
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: etcd cluster đang chạy trên 3 nodes (Phase 3), cert từ Phase 2 (Kubernetes CA + apiserver cert) đã phân phối.

## Bối cảnh

kube-apiserver thường chạy như static pod qua kubeadm. Bài này chúng ta sẽ chạy binary trực tiếp trên cả 3 master nodes (master-1, master-2, master-3) để hiểu chính xác cách thiết lập HA với API Server và thấy cách API Server giao tiếp với etcd cluster.

## Prerequisites

### etcd đang chạy trên cả 3 nodes

Chạy trên 1 master (vd: master-1) để kiểm tra toàn bộ etcd cluster:
```bash
# Verify etcd cluster health
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/healthcheck-client.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/healthcheck-client.key

etcdctl endpoint health
# https://192.168.56.11:2379 is healthy...
# https://192.168.56.12:2379 is healthy...
# https://192.168.56.13:2379 is healthy...
```

### Cert từ Phase 2 (Phải có trên cả 3 nodes)

Kiểm tra thư mục cert trên các node:
```bash
ls /etc/kubernetes/pki/
# ca.crt  ca.key  apiserver.crt  apiserver.key
# apiserver-etcd-client.crt  apiserver-etcd-client.key
# apiserver-kubelet-client.crt  apiserver-kubelet-client.key
# sa.pub  sa.key

ls /etc/kubernetes/pki/etcd/
# ca.crt  healthcheck-client.crt  healthcheck-client.key
# server.crt server.key peer.crt peer.key
```

> Nếu chưa có cert, quay lại Phase 2 và chạy script `gen-all-certs.sh` + `distribute-certs.sh`.

## Bước 1: Cài kube-apiserver + kubectl (Thực hiện trên 3 master nodes)

Bạn có thể mở tmux và bật synchronize-panes để chạy lệnh trên cả 3 nodes cùng lúc.

```bash
K8S_VERSION="v1.33.0"

# kube-apiserver
curl -fsSL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kube-apiserver" \
  -o /usr/local/bin/kube-apiserver
sudo chmod +x /usr/local/bin/kube-apiserver

# kubectl
curl -fsSL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl" \
  -o /usr/local/bin/kubectl
sudo chmod +x /usr/local/bin/kubectl

# Kiểm tra
kube-apiserver --version
kubectl version --client
```

## Bước 2: Tạo admin kubeconfig (Chỉ cần thực hiện trên master-1)

Tạo cấu hình cho kubectl (trên master-1) để giao tiếp với local API Server.

```bash
# Tạo kubeconfig cho admin (dùng ca.crt + admin cert)
kubectl config set-cluster k8s-lab \
  --server=https://127.0.0.1:6443 \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true \
  --kubeconfig=/tmp/admin.kubeconfig

# Dùng ca.key để tạo admin cert (CN=kubernetes-admin, O=system:masters)
openssl genrsa -out /tmp/admin-key.pem 2048
openssl req -new -key /tmp/admin-key.pem -out /tmp/admin.csr \
  -subj "/CN=kubernetes-admin/O=system:masters"
openssl x509 -req -in /tmp/admin.csr \
  -CA /etc/kubernetes/pki/ca.crt \
  -CAkey /etc/kubernetes/pki/ca.key \
  -CAcreateserial -out /tmp/admin.crt -days 365

kubectl config set-credentials kubernetes-admin \
  --client-certificate=/tmp/admin.crt \
  --client-key=/tmp/admin-key.pem \
  --embed-certs=true \
  --kubeconfig=/tmp/admin.kubeconfig

kubectl config set-context kubernetes-admin@k8s-lab \
  --cluster=k8s-lab \
  --user=kubernetes-admin \
  --kubeconfig=/tmp/admin.kubeconfig

kubectl config use-context kubernetes-admin@k8s-lab \
  --kubeconfig=/tmp/admin.kubeconfig
```

**Kiểm tra**: `/tmp/admin.kubeconfig` tồn tại, chứa cluster + user + context.

## Bước 3: Chạy kube-apiserver HA (nohup — tạm thời)

> **QUAN TRỌNG**: Nếu etcd có dữ liệu cũ từ lần chạy trước, xóa data trước để tránh lỗi. Chạy lệnh này trên master-1:
> ```bash
> export ETCDCTL_API=3
> export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
> export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
> export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/healthcheck-client.crt
> export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/healthcheck-client.key
> etcdctl del --prefix /registry/
> ```

Thực hiện lệnh sau trên **TẤT CẢ 3 master nodes**. 
Lưu ý quan trọng: Set biến `INTERNAL_IP` đúng với IP của máy hiện tại.

```bash
# Thiết lập IP của node hiện tại (Sửa 11 thành 12, 13 tương ứng trên các master khác)
INTERNAL_IP="192.168.56.13"

nohup sudo kube-apiserver \
  --advertise-address=${INTERNAL_IP} \
  --bind-address=0.0.0.0 \
  --apiserver-count=3 \
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
  --secure-port=6443 \
  --allow-privileged=true \
  --v=2 > /tmp/kube-apiserver.log 2>&1 &
```

> **Endpoint Reconciler**: Mỗi API Server chạy một vòng lặp ~10-30s, tự đăng ký IP của mình vào
> Service `kubernetes` (namespace `default`) trong etcd thông qua **lease TTL**.
> Khi một node chết, lease hết hạn → IP tự bị xóa khỏi Endpoint.
> Đây **không phải** leader election — không có "master" nào điều phối, mỗi API Server
> tự chịu trách nhiệm duy trì IP của chính nó. Flag `--apiserver-count=3` cho reconciler
> biết tổng số API Server để không bị ghi đè lẫn nhau.
> Kiểm tra log:
> ```bash
> tail -f /tmp/kube-apiserver.log
> ```

## Bước 3b: Kill nohup và chuyển sang systemd service

Sau khi đã verify API Server chạy ổn ở chế độ nohup, chúng ta sẽ chuyển sang chạy bằng **systemd** để:
- Tự động restart khi process crash.
- Tự start lại sau khi reboot VM.
- Quản lý log tập trung qua `journalctl`.

### Kill process nohup đang chạy

Thực hiện trên **TẤT CẢ 3 master nodes**:

```bash
# Kill toàn bộ process kube-apiserver đang chạy
sudo pkill kube-apiserver

# Xác nhận process đã dừng (không có output = đã dừng)
pgrep kube-apiserver
```

### Tạo systemd unit file

Thực hiện trên **TẤT CẢ 3 master nodes** (thay `INTERNAL_IP` đúng với IP node hiện tại):

```bash
# master-1: 192.168.56.11 | master-2: 192.168.56.12 | master-3: 192.168.56.13
INTERNAL_IP="192.168.56.13"

cat <<EOF | sudo tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
After=network.target etcd.service
Wants=etcd.service

[Service]
Type=notify
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${INTERNAL_IP} \\
  --bind-address=0.0.0.0 \\
  --apiserver-count=3 \\
  --etcd-servers=https://127.0.0.1:2379 \\
  --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt \\
  --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt \\
  --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key \\
  --client-ca-file=/etc/kubernetes/pki/ca.crt \\
  --tls-cert-file=/etc/kubernetes/pki/apiserver.crt \\
  --tls-private-key-file=/etc/kubernetes/pki/apiserver.key \\
  --service-account-key-file=/etc/kubernetes/pki/sa.pub \\
  --service-account-signing-key-file=/etc/kubernetes/pki/sa.key \\
  --service-account-issuer=https://kubernetes.default.svc.cluster.local \\
  --service-cluster-ip-range=10.96.0.0/12 \\
  --authorization-mode=Node,RBAC \\
  --enable-admission-plugins=NodeRestriction,ServiceAccount \\
  --anonymous-auth=false \\
  --secure-port=6443 \\
  --allow-privileged=true \\
  --v=2
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

### Enable và start service

```bash
# Reload systemd để nhận unit file mới
sudo systemctl daemon-reload

# Enable service: tự start sau reboot
sudo systemctl enable kube-apiserver

# Start service ngay lập tức
sudo systemctl start kube-apiserver

# Kiểm tra status
sudo systemctl status kube-apiserver
```

### Verify service chạy đúng

```bash
# Xem log real-time (Ctrl+C để thoát)
sudo journalctl -u kube-apiserver -f

# Health check
curl -k --cert /tmp/admin.crt --key /tmp/admin-key.pem \
  https://127.0.0.1:6443/healthz
# ok
```

> **Tại sao dùng `Type=notify`?**  
> `kube-apiserver` hỗ trợ systemd sd_notify — nó báo cho systemd biết khi nào đã sẵn sàng nhận request (thay vì systemd cứ đợi timeout). Nếu binary không hỗ trợ notify, đổi sang `Type=simple`.

### Giải thích các flags HA

| Flag | Ý nghĩa |
|------|---------|
| `--advertise-address` | IP mà API Server quảng bá cho cluster biết. Phải khớp IP node hiện tại. |
| `--apiserver-count=3` | Khai báo số lượng API Server chạy HA để Endpoint Reconciler chia tải hợp lý. |
| `--etcd-servers` | etcd endpoint — Do etcd chạy cùng VM (Stacked topology), ta trỏ thẳng vào `https://127.0.0.1:2379` để kết nối etcd cục bộ. |

## Bước 4: Verify API Server chạy (Kiểm tra trên master-1)

```bash
# Health check với admin cert
curl -k --cert /tmp/admin.crt --key /tmp/admin-key.pem \
  https://127.0.0.1:6443/healthz
# ok

# Version với admin cert
curl -k --cert /tmp/admin.crt --key /tmp/admin-key.pem \
  https://127.0.0.1:6443/version
# {"major":"1","minor":"33","gitVersion":"v1.33.0",...}
```

## Bước 5: Dùng kubectl kiểm tra Cluster

Vì API Server đang chạy ở dạng HA, chúng tạo nên cluster API endpoint hợp nhất.
Trên `master-1`:

```bash
export KUBECONFIG=/tmp/admin.kubeconfig

# List namespaces (chưa có namespace nào)
kubectl get namespaces

# Tạo namespace
kubectl create namespace default
kubectl create namespace kube-system

# Kiểm tra Endpoint 'kubernetes' mặc định tự sinh ra:
kubectl get endpoints kubernetes -n default
# Bạn sẽ thấy ENDPOINTS bao gồm IP của cả 3 master (192.168.56.11:6443, 192.168.56.12:6443, 192.168.56.13:6443)

# Tạo pod (API Server sẽ lưu thông tin pod xuống etcd)
kubectl run nginx --image=nginx -n default
```

> **LƯU Ý - STANDALONE MODE**: Trong môi trường không có controller-manager đang chạy, bạn cần tạo ConfigMap và ServiceAccount mặc định bằng tay để thử nghiệm:
```bash
kubectl create serviceaccount default -n default
kubectl create serviceaccount default -n kube-system
kubectl create configmap kube-root-ca.crt \
  --from-file=ca.crt=/etc/kubernetes/pki/ca.crt \
  -n default
kubectl create configmap kube-root-ca.crt \
  --from-file=ca.crt=/etc/kubernetes/pki/ca.crt \
  -n kube-system
```

## Bước 6: Kiểm tra etcd — Dữ liệu được đồng bộ

API Server ghi dữ liệu vào etcd. Dữ liệu này sẽ có sẵn cho cả 3 apiserver.

```bash
# Đếm key
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/healthcheck-client.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/healthcheck-client.key

etcdctl get --prefix /registry/ --keys-only
# /registry/namespaces/default
# /registry/namespaces/kube-system
# /registry/pods/default/nginx
```

## Bước 7: Thử nghiệm High Availability (HA)

1. Tắt `kube-apiserver` trên `master-1`:
```bash
sudo systemctl stop kube-apiserver
```
2. Sửa file kubeconfig trỏ tới `master-2`:
```bash
kubectl config set-cluster k8s-lab --server=https://192.168.56.12:6443
```
3. Chạy lại lệnh kubectl:
```bash
kubectl get namespaces
# Vẫn hoạt động bình thường, dữ liệu được lấy từ etcd qua API Server master-2
```
4. Bật lại API Server trên `master-1`:
```bash
sudo systemctl start kube-apiserver
```

## Cleanup

```bash
# Stop và disable service trên cả 3 nodes
sudo systemctl stop kube-apiserver
sudo systemctl disable kube-apiserver

# Xóa unit file
sudo rm /etc/systemd/system/kube-apiserver.service
sudo systemctl daemon-reload

# Xóa data etcd (nếu muốn clean start)
etcdctl del --prefix /registry/
```

## Câu hỏi tự kiểm tra

1. API Server cần tối thiểu những flag nào để start?
2. Tại sao API Server cần `--service-account-signing-key-file`?
3. Nếu 1 trong 3 API Server down, điều gì xảy ra khi client vẫn đang kết nối tới nó? Cần thành phần nào để xử lý?
4. Nếu etcd down toàn bộ, điều gì xảy ra với API Server?
5. Tại sao cần `--apiserver-count=3`?

## Đáp án tham khảo

1. `--etcd-servers` + etcd cert + `--client-ca-file` + `--tls-cert-file` + `--tls-private-key-file` + `--authorization-mode` + `--service-cluster-ip-range`.
2. Để sign JWT (Service Account token). Pod dùng JWT gọi API Server, API Server verify signature bằng `--service-account-key-file` (public key tương ứng).
3. Client sẽ bị Timeout/Connection Refused. Cần một **Load Balancer (HAProxy/Nginx)** đứng trước 3 API Server. Khi đó client cấu hình gọi IP của Load Balancer, nếu 1 API Server sập, LB tự điều hướng sang API Server còn lại.
4. API Server sẽ không hoạt động bình thường (trả 500 hoặc 503) vì API server hoàn toàn stateless, etcd là "bộ nhớ" duy nhất.
5. Giúp Endpoint Reconciler hoạt động trơn tru. Khi master-1 start, nó sẽ thêm IP của nó vào Endpoint `kubernetes` ở namespace `default`. Khi `--apiserver-count=3`, kubernetes sẽ tự hiểu và duy trì danh sách gồm cả 3 master trong Endpoint, tránh việc đè chéo IP của nhau.
