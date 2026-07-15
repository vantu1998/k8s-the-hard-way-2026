# Kubernetes The Hard Way 2026 — Learning Plan

## Mục tiêu tổng quan

Sau khi hoàn thành lộ trình này, bạn sẽ:

- Hiểu kiến trúc Kubernetes từ bên trong — biết chính xác component nào làm gì, gọi ai, bằng cơ chế nào.
- Tự bootstrap một Kubernetes cluster từ đầu (không dùng kubeadm).
- Debug được lỗi thực tế ở mức hệ điều hành, network, và Kubernetes control plane.
- Hiểu chính xác kubeadm đang tự động làm những bước nào — để biết nó giấu gì.

## Cách dùng plan này

Mỗi phase có 4 phần:

| Phần | Ý nghĩa |
|---|---|
| **Mục tiêu** | Bạn sẽ làm được gì sau khi xong phase |
| **Khái niệm cần nắm** | Kiến thức lý thuyết cụ thể, không chỉ tên mà có giải thích |
| **Thực hành** | Bài tập hands-on để chứng minh đã hiểu |
| **Checkpoint** | Điều kiện để đánh dấu phase hoàn thành |

Ghi chú và bài tập đặt trong `phases/phase-XX-*/` của repo.

---

# Phase 0 — Linux Foundation

> Thư mục: `phases/phase-00-linux-foundation/`

## Mục tiêu

Hiểu đủ Linux kernel primitives để biết container "dùng gì" để cách ly tiến trình, giới hạn tài nguyên, và giao tiếp mạng. Đây là nền tảng cho mọi phase sau.

## Khái niệm cần nắm

### Process & Isolation

- **Process vs Thread**: fork/exec/wait, zombie/orphan process, signal (SIGTERM, SIGKILL, SIGINT).
- **Linux Namespaces**: PID, NET, MNT, IPC, UTS, USER, CGROUP. Mỗi namespace cách ly gì? Cách xem namespace của một process qua `/proc/<pid>/ns/`.
- **cgroups v2**: Cấu trúc `/sys/fs/cgroup/`, cách tạo cgroup, gán process, đặt limit CPU/memory. Khác biệt cgroups v1 vs v2 (unified hierarchy).
- **Linux Capabilities**: `CAP_NET_ADMIN`, `CAP_SYS_ADMIN`, `CAP_NET_BIND_SERVICE`... Container thường cần capability nào? Cách drop capability.
- **OverlayFS**: Lowerdir, upperdir, mergeddir. Cách overlayfs tạo image layer cho container. Thực hành mount overlay bằng tay.

### systemd

- Unit file structure (Service, Socket, Timer, Target).
- `systemctl`, `journalctl`, `systemd-analyze`.
- Cách viết unit file cho một service đơn giản, quản lý restart policy.
- systemd cgroup integration — systemd quản lý cgroup thế nào.

### Networking

- **TCP/IP stack**: OSI model vs TCP/IP model, handshake, TIME_WAIT, socket states.
- **Bridge, veth, Network Namespace**: Tạo netns, veth pair nối 2 netns, bridge switch ảo. Đây chính là cách container networking hoạt động.
- **Routing & ARP**: Routing table (`ip route`), ARP table (`ip neigh`), cách packet đi từ pod ra ngoài node.
- **iptables/nftables**: Table, chain, rule, target (ACCEPT, DROP, MASQUERADE, DNAT, SNAT). Cách iptables làm service proxy trong Kubernetes.
- **Tools**: `tcpdump` (capture packet, filter expression), `ss` (socket statistics), `iproute2` (`ip addr`, `ip link`, `ip route`, `ip netns`).

## Thực hành

1. Tạo 2 network namespace, nối bằng veth pair, ping qua lại.
2. Tạo cgroup v2, giới hạn CPU cho một process, quan sát throttling.
3. Mount overlayfs bằng tay: tạo lowerdir/upperdir/mergeddir, ghi file, quan sát whiteout.
4. Dùng `tcpdump` capture traffic giữa 2 netns, đọc được handshake TCP.
5. Viết systemd unit file cho một script Python, enable & start, xem log bằng `journalctl`.
6. Dùng `unshare` tạo process với PID namespace riêng, quan sát PID 1 bên trong.

## Checkpoint

- [ ] Giải thích được container = namespaces + cgroups + overlayfs, và từng cái làm gì.
- [ ] Tạo được 2 netns nối veth, ping thành công, capture được packet bằng tcpdump.
- [ ] Viết được systemd unit file chạy service tự động restart.
- [ ] Đọc được iptables rules và hiểu flow packet đi qua chain nào.

---

# Phase 1 — Container Runtime

> Thư mục: `phases/phase-01-container-runtime/`

## Mục tiêu

Hiểu container runtime stack từ dưới lên: OCI runtime (runc) → high-level runtime (containerd) → CRI interface. Biết `docker run` thực sự gọi gì bên dưới.

## Khái niệm cần nắm

- **OCI Runtime Spec**: Định nghĩa config.json chỉ định rootfs, namespaces, cgroups, process. runc đọc spec này để tạo container.
- **OCI Image Spec**: Image manifest, layer, config — cấu trúc image trước khi unpack thành rootfs.
- **runc**: CLI trực tiếp tạo container từ OCI bundle (`runc create`, `runc start`, `runc exec`). Đây là layer thấp nhất.
- **containerd**: Daemon quản lý image pull/push, container lifecycle, snapshot. Chạy runc bên dưới. Kiến trúc containerd: `containerd-shim` per container.
- **CRI (Container Runtime Interface)**: gRPC interface giữa kubelet và runtime. Proto spec: `RuntimeService` (pod sandbox, container) + `ImageService` (pull/list image).
- **crictl**: CLI giao tiếp với CRI runtime — xem pod, container, image, log. Tương tự `docker` nhưng cho CRI.
- **ctr**: CLI trực tiếp cho containerd — debug containerd mà không qua CRI. `ctr images pull`, `ctr run`, `ctr containers list`.

## Thực hành

1. Tạo OCI bundle bằng tay: viết `config.json`, chuẩn bị rootfs, chạy `runc run`.
2. Cài containerd, dùng `ctr` pull image nginx, run container, exec vào.
3. Dùng `crictl` kết nối containerd qua CRI socket, list pod sandbox, list container.
4. So sánh output `ctr run` vs `crictl runp` — hiểu sự khác biệt layer.
5. Kill `containerd-shim` của một container, quan sát container bị ảnh hưởng thế nào.

## Checkpoint

- [ ] Vẽ được stack: kubelet → CRI gRPC → containerd → containerd-shim → runc → kernel namespaces/cgroups.
- [ ] Tạo được container bằng `runc` từ OCI bundle thủ công.
- [ ] Giải thích được khác biệt `ctr` vs `crictl` vs `docker`.
- [ ] Pull image bằng `ctr`, xem image layer được unpack vào snapshotter nào.

---

# Phase 2 — PKI & Certificates

> Thư mục: `phases/phase-02-pki-certificates/`

## Mục tiêu

Hiểu đủ PKI/TLS để tự sinh toàn bộ certificate cho Kubernetes cluster: CA, server cert cho từng component, client cert cho kubelet, etcd peer cert.

## Khái niệm cần nắm

- **CA (Certificate Authority)**: Root CA, Intermediate CA. Self-signed root cert, sign cert con. Cách tạo CA bằng `openssl` hoặc `cfssl`.
- **TLS Handshake**: ClientHello, ServerHello, certificate exchange, key exchange, session key. Khác biệt TLS 1.2 vs 1.3.
- **CSR (Certificate Signing Request)**: Cấu trúc CSR, cách tạo CSR bằng `openssl req`. CA ký CSR thành certificate.
- **SAN (Subject Alternative Name)**: Tại sao cần SAN (không chỉ dùng CN). DNS SAN vs IP SAN. Kubernetes cần SAN cho tất cả endpoint (IP node, service IP, hostname).
- **CN (Common Name)**: CN trong Kubernetes = username cho RBAC. O (Organization) = group.
- **Certificate Signing**: Quá trình CA ký CSR: hash, signature, serial number, validity period.
- **Kubernetes Certificates**: Mỗi component cần cert nào:
  - `kube-apiserver`: server cert với SAN cho tất cả API endpoint.
  - `kubelet`: client cert (gọi API server) + server cert (API server gọi kubelet).
  - `etcd`: server cert + peer cert (mTLS giữa etcd members).
  - `controller-manager`, `scheduler`: client cert gọi API server.
  - `service-account`: private key để sign JWT.

## Thực hành

1. Tạo root CA bằng `openssl`: private key + self-signed cert.
2. Tạo CSR cho `kube-apiserver` với SAN chứa IP node + `kubernetes` + `kubernetes.default.svc.cluster.local`.
3. Ký CSR bằng CA, verify cert bằng `openssl verify`.
4. Tạo etcd peer cert với mTLS, test handshake bằng `openssl s_client`.
5. Viết script sinh toàn bộ cert cho cluster 3 master + 2 worker (đặt trong `phases/phase-02-pki-certificates/scripts/`).

## Checkpoint

- [ ] Giải thích được TLS handshake từng bước.
- [ ] Tạo được CA + sign cert với đúng SAN.
- [ ] Liệt kê được tất cả cert Kubernetes cần và mỗi cert phục vụ ai.
- [ ] Script sinh cert chạy thành công, verify bằng `openssl verify`.

---

# Phase 3 — etcd

> Thư mục: `phases/phase-03-etcd/`

## Mục tiêu

Hiểu etcd đủ để vận hành: bootstrap cluster 3 node, snapshot/restore, debug dữ liệu Kubernetes bên trong etcd.

## Khái niệm cần nắm

- **Kiến trúc etcd**: Raft protocol, leader election, log replication. etcd v3 API (gRPC) vs etcdctl v2. Cấu hình `--listen-client-urls`, `--advertise-client-urls`, `--listen-peer-urls`, `--initial-cluster`.
- **Raft Consensus**: Term, log entry, commit index, leader/follower/candidate. Quorum = (N/2)+1. Tại sao cluster 3 node chịu được 1 failure, 5 node chịu được 2.
- **Member Management**: `etcdctl member add/remove/list`. Thêm node vào cluster đang chạy. Xóa node, rebalance.
- **Snapshot & Restore**: `etcdctl snapshot save`, `etcdctl snapshot restore`. Khi nào cần restore (disaster recovery). Restore tạo data dir mới, cần restart etcd.
- **Compact & Defrag**: etcd giữ history (MVCC). Compact xóa revision cũ, defrag giải phóng disk. `etcdctl compact`, `etcdctl defrag`. Tác dụng của `--auto-compaction-retention`.
- **Dữ liệu Kubernetes trong etcd**: Key prefix `/registry/pods/`, `/registry/services/`, `/registry/deployments/`... Dùng `etcdctl get --prefix /registry/` xem raw data. Hiểu etcd là single source of truth cho cluster state.

## Thực hành

1. Bootstrap etcd cluster 3 node trên 3 VM/machine, cấu hình peer URL + client URL + mTLS.
2. Dùng `etcdctl` put/get/delete key, xem status, endpoint health.
3. Snapshot etcd, kill 1 node, restore từ snapshot, rejoin cluster.
4. `etcdctl get --prefix /registry/ --keys-only` trên cluster Kubernetes đang chạy, đếm số key.
5. Compact + defrag, quan sát disk usage trước/sau.
6. Giết leader, quan sát election mới trong log.

## Checkpoint

- [ ] Bootstrap được etcd 3 node với mTLS.
- [ ] Snapshot + restore thành công, cluster rejoin.
- [ ] Đọc được dữ liệu Kubernetes trong etcd bằng `etcdctl get --prefix`.
- [ ] Giải thích được Raft quorum và tại sao 3 node chịu được 1 failure.

---

# Phase 4 — Kubernetes API Server

> Thư mục: `phases/phase-04-api-server/`

## Mục tiêu

Hiểu API Server là "cửa ngõ duy nhất" — mọi tương tác đều qua nó. Nắm được flow request từ client đến etcd.

## Khái niệm cần nắm

- **kube-apiserver**: Cấu hình chính: `--etcd-servers`, `--client-ca-file`, `--tls-cert-file`, `--service-account-key-file`, `--authorization-mode`, `--enable-admission-plugins`. API Server là stateless — có thể chạy nhiều instance song song.
- **Authentication**: Client cert (CN=username, O=group), Bearer token, OIDC. API Server xác định "ai" gửi request.
- **Authorization**: RBAC (Role/ClusterRole + RoleBinding/ClusterRoleBinding), ABAC, Node authorization. Flow: Authentication → Authorization → Admission.
- **Admission Controller**: Mutating (sửa request trước khi lưu — e.g. `default-storageclass`, `service-account`), Validating (kiểm tra — e.g. `NamespaceLifecycle`, `ResourceQuota`). Webhook admission (OPA Gatekeeper, Kyverno).
- **API Flow**: Client → Authentication → Authorization → Mutating Admission → Validation → etcd → watch event → controller/kubelet. Hiểu request đi qua cache (watch) vs read (list/get).
- **Encryption at Rest**: `--encryption-provider-config`. AES-CBC, AES-GCM, secretbox. Mã hóa Secret trong etcd. Key rotation.

## Thực hành

1. Chạy `kube-apiserver` standalone (không kubelet/controller), dùng `kubectl` gọi API.
2. Tạo user cert với CN=`alice`, O=`dev`, tạo RoleBinding, test RBAC — alice có quyền gì, không có quyền gì.
3. Enable admission webhook, viết một ValidatingAdmissionWebhook từ chối pod không có label.
4. Enable encryption at rest, tạo Secret, đọc raw trong etcd — thấy đã mã hóa.
5. Dùng `kubectl --v=8` xem HTTP request/response đầy đủ đến API Server.

## Checkpoint

- [ ] Vẽ được flow: Client → Authn → Authz → Admission → etcd → Watch → Controller/Kubelet.
- [ ] Tạo được user bằng cert + RBAC, test permission thành công.
- [ ] Giải thích được Mutating vs Validating Admission Controller.
- [ ] Bật encryption at rest, verify Secret mã hóa trong etcd.

---

# Phase 5 — Scheduler

> Thư mục: `phases/phase-05-scheduler/`

## Mục tiêu

Hiểu scheduler quyết định pod chạy trên node nào, và biết can thiệp scheduling bằng affinity/taint/toleration/priority.

## Khái niệm cần nắm

- **Scheduling Process**: 2 phase — Filter (đ loại node không phù hợp) + Score (rank node còn lại). Scheduler chạy standalone, watch pending pod, bind pod → node.
- **Scheduling Algorithms**: Filter: PodFitsResources, PodFitsHostPorts, MatchNodeSelector, NoVolumeZoneConflict. Score: LeastRequestedPriority, BalancedResourceAllocation, NodeAffinityPriority.
- **Node Selection**: `nodeSelector` (label đơn giản), `nodeAffinity` (required/preferred, operator In/NotIn/Exists).
- **Pod Affinity/Anti-Affinity**: Co-locate pod trên cùng node (affinity) hoặc tách node (anti-affinity). Dùng cho replica spread.
- **Taints & Tolerations**: `NoSchedule`, `NoExecute`, `PreferNoSchedule`. Taint node để đuổi pod, toleration để pod chịu được taint. Use case: dedicated node, node đang sửa.
- **Priority & Preemption**: PriorityClass, high priority pod evict low priority pod. Preemption chọn victim pod nào để evict.

## Thực hành

1. Tạo 3 node với label khác nhau (`zone=a`, `zone=b`, `zone=c`), deploy pod với `nodeAffinity` preferred, quan sát distribution.
2. Taint 1 node `NoSchedule`, deploy pod không có toleration, quan sát pod không schedule lên node đó.
3. Tạo PriorityClass high/low, deploy high priority pod khi node full, quan sát preemption.
4. Deploy pod với podAntiAffinity, quan sát replica spread đều ra các node.
5. Xem scheduler log: `kubectl logs -n kube-system kube-scheduler-<node>`, tìm decision log.

## Checkpoint

- [ ] Giải thích được 2 phase Filter + Score.
- [ ] Dùng được nodeAffinity, podAntiAffinity, taint/toleration, priority/preemption.
- [ ] Đọc được scheduler log biết pod bị schedule lên node nào, tại sao.

---

# Phase 6 — Controller Manager

> Thư mục: `phases/phase-06-controller-manager/`

## Mục tiêu

Hiểu controller pattern (watch + reconcile loop) — nguyên lý cốt lõi của Kubernetes. Nắm được từng controller chính làm gì.

## Khái niệm cần nắm

- **Controller Pattern**: Watch API resource → compare desired state vs actual state → act to converge. Reconcile loop chạy liên tục, idempotent. Ví dụ: Deployment controller watch Deployment, tạo ReplicaSet, ReplicaSet controller watch ReplicaSet, tạo Pod.
- **ReplicaSet Controller**: Đảm bảo số replica. Scale up (tạo pod), scale down (xóa pod theo policy). Selector matching.
- **Deployment Controller**: Quản lý ReplicaSet cho rolling update. Tạo ReplicaSet mới, scale lên, scale ReplicaSet cũ xuống. Rollback = scale RS cũ lên.
- **Node Controller**: Watch node status, mark node NotReady khi heartbeat timeout. Evict pod sau `pod-eviction-timeout`.
- **Job/CronJob Controller**: Job tạo pod đến khi completions đủ. CronJob tạo Job theo schedule. Parallelism, backoffLimit.
- **Namespace Controller**: Xóa resource trong namespace khi namespace bị delete. Finalizer pattern.

## Thực hành

1. Scale Deployment từ 1 → 5, xem ReplicaSet controller tạo pod từng cái trong event log.
2. Rolling update image, quan sát 2 ReplicaSet (cũ + mới) cùng tồn tại, pod thay đổi dần.
3. Rollback rollout, quan sát ReplicaSet cũ scale lên lại.
4. Cordone + drain node, quan sát Node controller + DaemonSet controller behavior.
5. Tạo Job với `completions: 5`, `parallelism: 2`, quan sát pod chạy 2 cái lúc.
6. Viết một simple controller bằng Python (watch ConfigMap, tạo file) — hiểu reconcile loop bằng tay.

## Checkpoint

- [ ] Giải thích được reconcile loop bằng ví dụ Deployment → ReplicaSet → Pod.
- [ ] Quan sát được rolling update tạo 2 ReplicaSet.
- [ ] Viết được simple controller watch + react.

---

# Phase 7 — Kubelet

> Thư mục: `phases/phase-07-kubelet/`

## Mục tiêu

Hiểu kubelet — agent trên mỗi node quản lý pod lifecycle từ API Server đến container runtime.

## Khái niệm cần nắm

- **Node Registration**: Kubelet register node với API Server (`--register-node=true`). Gửi node status (capacity, allocatable, conditions) định kỳ. Heartbeat qua lease hoặc node status update.
- **TLS Bootstrap**: Kubelet join cluster không cần cert sẵn — dùng bootstrap token, request CSR, API Server ký, kubelet nhận cert. `kubelet.conf` bootstrap → cert rotation.
- **Pod Lifecycle**: SyncLoop — kubelet watch pod assigned cho node, gọi CRI tạo sandbox + container, report status. Pod update → sync pod (recreate container). Graceful shutdown — `terminationGracePeriodSeconds`, preStop hook.
- **Static Pods**: Pod manifest trong `/etc/kubernetes/manifests/`, kubelet watch thư mục, chạy pod trực tiếp (không qua API Server). API Server thấy static pod nhưng không quản lý. Cách control plane chạy as static pod.
- **Health Checking**: Liveness probe (restart container khi fail), Readiness probe (remove từ Service endpoints), Startup probe (chỉ check lúc khởi động). Probe type: HTTP, TCP, exec.

## Thực hành

1. Chạy kubelet standalone, tạo pod manifest YAML, đặt vào `/etc/kubernetes/manifests/`, quan sát kubelet chạy pod.
2. Join worker node vào cluster bằng TLS bootstrap token, xem CSR trong `kubectl get csr`.
3. Deploy pod với liveness probe HTTP, kill endpoint, quan sát container restart.
4. Deploy pod với preStop hook + `terminationGracePeriodSeconds: 60`, delete pod, quan sát graceful shutdown.
5. Xem kubelet log: `journalctl -u kubelet`, tìm syncPod event.

## Checkpoint

- [ ] Chạy được static pod bằng manifest trong `/etc/kubernetes/manifests/`.
- [ ] Join node bằng TLS bootstrap, CSR được approve.
- [ ] Giải thích được SyncLoop và graceful shutdown flow.
- [ ] Cấu hình được liveness/readiness/startup probe.

---

# Phase 8 — Container Runtime Interface (CRI)

> Thư mục: `phases/phase-08-cri/`

## Mục tiêu

Hiểu chi tiết giao tiếp giữa kubelet và container runtime qua CRI gRPC — từ Pod sandbox đến container start.

## Khái niệm cần nắm

- **CRI Architecture**: kubelet gọi CRI runtime qua Unix socket (`/run/containerd/containerd.sock`). gRPC service: `RuntimeService` (sandbox + container) + `ImageService`. kubelet không biết runtime là gì, chỉ biết CRI interface.
- **kubelet ↔ containerd**: kubelet gọi `RunPodSandbox` → tạo network namespace, CNI setup. Sau đó `CreateContainer` → `StartContainer`. Containerd delegate cho runc.
- **Image Management**: `PullImage` (kubelet pull image khi pod cần), `ListImages`, `ImageStatus`. Image pull policy: `Always`, `IfNotPresent`, `Never`.
- **Pod Sandbox**: Khái niệm sandbox = network namespace + IPC namespace cho pod. Tất cả container trong pod share sandbox. CRI tạo sandbox trước, container sau.

## Thực hành

1. Cấu hình kubelet dùng containerd (`--container-runtime-endpoint=unix:///run/containerd/containerd.sock`).
2. Deploy pod 2 container share volume, quan sát sandbox + 2 container trong `crictl ps`.
3. `crictl inspect <sandbox-id>` — xem network namespace, cgroup path.
4. Pull image thủ công bằng `crictl pull`, deploy pod với `imagePullPolicy: Never`, quan sát dùng image local.
5. Strace kubelet khi tạo pod, tìm gRPC call đến containerd socket.

## Checkpoint

- [ ] Giải thích được Pod Sandbox là gì và tại sao container trong pod share network.
- [ ] Dùng `crictl` inspect được sandbox + container.
- [ ] Mô tả được flow: kubelet → CRI gRPC → containerd → runc.

---

# Phase 9 — CNI

> Thư mục: `phases/phase-09-cni/`

## Mục tiêu

Hiểu cách pod nhận IP, giao tiếp network, và network policy kiểm soát traffic. Nắm được CNI plugin chạy gì khi pod start.

## Khái niệm cần nắm

- **CNI Specification**: CNI plugin là binary được gọi lúc pod sandbox tạo. Input: JSON config + env var (`CNI_COMMAND=ADD`, `CNI_CONTAINERID`, `CNI_NETNS`). Output: JSON chứa IP. Plugin chain (multus).
- **Bridge Network**: Tạo bridge `cbr0`, veth pair: một đầu trong pod netns, một đầu gắn bridge. Pod IP từ IPAM, route trên node. Đây là cách bridge CNI hoạt động.
- **Pod Networking**: Mỗi pod có IP riêng, pod trong cùng node giao tiếp qua bridge, pod khác node giao tiếp qua routing/overlay. Model: flat, overlay (VXLAN), BGP.
- **IPAM**: Host-local (cấp IP từ CIDR range trên node), DHCP, Calico IPAM (block-based). Node nhận CIDR range từ controller manager `--cluster-cidr`.
- **Network Policies**: Layer 3/4 firewall cho pod. Ingress rule (ai được gọi vào), Egress rule (pod được gọi ra). Default deny + allow pattern. CNI plugin enforce (iptables hoặc eBPF).
- **Cilium/Calico**: Cilium dùng eBPF (không iptables), Calico dùng iptables/BPF. Hiểu sau khi nắm bridge + IPAM + policy cơ bản.

## Thực hành

1. Cài bridge CNI thủ công: viết CNI config JSON, deploy pod, `crictl inspect` xem IP gán.
2. Tạo 2 pod khác node, trace packet path: pod → veth → bridge → route → node interface → remote node.
3. Tạo NetworkPolicy default deny ingress, test pod không nhận traffic. Add allow rule, test lại.
4. Cài Calico hoặc Cilium, so sánh cách quản lý IPAM và policy enforcement.
5. `tcpdump` trên veth interface của pod, capture traffic giữa 2 pod.

## Checkpoint

- [ ] Giải thích được flow: pod start → CNI plugin ADD → veth + IP + route.
- [ ] Tạo được NetworkPolicy default deny + allow.
- [ ] Trace được packet path giữa 2 pod khác node.

---

# Phase 10 — kube-proxy

> Thư mục: `phases/phase-10-kube-proxy/`

## Mục tiêu

Hiểu Service abstraction — cách Kubernetes load balance traffic đến pod, và kube-proxy implement bằng iptables/IPVS/eBPF.

## Khái niệm cần nắm

- **Service**: Abstraction trên pod, stable IP + DNS. Service không tồn tại trong network — nó là iptables rule trên mỗi node. EndpointSlice track pod IP sẵn sàng.
- **ClusterIP**: Virtual IP, iptables rule DNAT packet đến ClusterIP → random pod IP. `KUBE-SERVICES` chain.
- **NodePort**: Mở port trên mọi node, iptables DNAT → ClusterIP → pod. Range 30000-32767.
- **LoadBalancer**: Cloud provider cấp external IP, traffic forward đến NodePort. MetalLB cho bare metal.
- **iptables Mode**: Mỗi Service = chain iptables. `KUBE-SVC-<hash>` chain chứa rule DNAT đến pod. `KUBE-SEP-<hash>` per endpoint. Random probability cho load balance. O(n) rule — chậm khi nhiều Service.
- **IPVS Mode**: Dùng IPVS (kernel module) thay iptables. Load balancing algorithm: rr, wrr, lc, sh. Nhanh hơn iptables với nhiều Service.
- **eBPF Proxy Replacement**: Cilium thay kube-proxy bằng eBPF program ở socket layer. Bypass iptables entirely, faster.

## Thực hành

1. Tạo Service ClusterIP + 3 pod, `iptables-save | grep KUBE-SVC` xem rule DNAT.
2. Curl ClusterIP nhiều lần, quan sát traffic chia đều ra 3 pod (xem access log).
3. Tạo NodePort, curl từ ngoài node, trace iptables rule DNAT.
4. Chuyển kube-proxy sang IPVS mode, `ipvsadm -L -n` xem virtual server + real server.
5. Cài Cilium với kube-proxy replacement, `kubectl -n kube-system delete ds kube-proxy`, test Service vẫn hoạt động.

## Checkpoint

- [ ] Đọc được iptables rule cho một Service, hiểu flow DNAT.
- [ ] Giải thích được khác biệt iptables vs IPVS vs eBPF mode.
- [ ] Trace được packet: curl ClusterIP → iptables DNAT → pod IP.

---

# Phase 11 — CoreDNS

> Thư mục: `phases/phase-11-coredns/`

## Mục tiêu

Hiểu DNS resolution trong Kubernetes — pod tìm Service bằng tên (`my-svc.my-namespace.svc.cluster.local`) hoạt động thế nào.

## Khái niệm cần nắm

- **DNS Resolution**: Pod inherit `/etc/resolv.conf` từ kubelet config (`--cluster-dns`). Nameserver = CoreDNS ClusterIP. Search domain: `namespace.svc.cluster.local`, `svc.cluster.local`, `cluster.local`.
- **Service Discovery**: Service A record (`my-svc.my-namespace.svc.cluster.local` → ClusterIP). Headless Service (ClusterIP=None) → trả pod IP trực tiếp. SRV record cho named port.
- **DNS Records**: A/AAAA (Service), SRV (named port), PTR (reverse lookup). Pod DNS: `pod-ip-dashed.namespace.pod.cluster.local`.
- **CoreDNS Plugins**: `kubernetes` plugin (serve K8s DNS từ API), `forward` (upstream DNS), `cache`, `rewrite`, `hosts`. CoreDNS ConfigMap trong `kube-system`.

## Thực hành

1. Deploy pod, `nslookup kubernetes.default.svc.cluster.local` — thấy API Server ClusterIP.
2. Tạo headless Service, `nslookup` — thấy pod IP thay vì ClusterIP.
3. Sửa CoreDNS ConfigMap thêm `rewrite` rule, restart CoreDNS, test.
4. `kubectl -n kube-system edit cm coredns` — xem plugin chain, hiểu flow query.
5. Deploy pod với `dnsPolicy: ClusterFirst` vs `Default` vs `None`, so sánh `/etc/resolv.conf`.

## Checkpoint

- [ ] Giải thích được flow: pod curl `my-svc` → resolv.conf → CoreDNS → kubernetes plugin → API Server → Service ClusterIP.
- [ ] Phân biệt Service vs Headless Service DNS response.
- [ ] Sửa được CoreDNS ConfigMap thêm plugin.

---

# Phase 12 — Ingress

> Thư mục: `phases/phase-12-ingress/`

## Mục tiêu

Hiểu Ingress — định tuyến HTTP/HTTPS traffic từ ngoài cluster vào Service, dựa trên host/path.

## Khái niệm cần nắm

- **Ingress Resource**: API object định nghĩa rule routing: host → path → Service. IngressClass chỉ định controller nào xử lý.
- **Ingress Controller**: Pod chạy proxy (NGINX, Traefik, HAProxy) watch Ingress resource, sinh config file, reload. Không có Ingress Controller thì Ingress resource không có tác dụng.
- **NGINX Ingress**: Cài `ingress-nginx`, config template, annotation (`nginx.ingress.kubernetes.io/rewrite-target`, `ssl-redirect`). NGINX chạy trong pod, NodePort/LoadBalancer expose.
- **HTTP Routing**: Host-based (`api.example.com` → Service A), Path-based (`/api` → Service A, `/web` → Service B). Regex path.
- **TLS**: Certificate gắn vào Ingress qua Secret. NGINX terminate TLS, forward HTTP đến Service. cert-manager auto-issue cert (Let's Encrypt).

## Thực hành

1. Cài ingress-nginx, deploy 2 deployment + 2 Service, tạo Ingress host-based routing.
2. Curl Ingress controller IP với `Host` header, quan sát routing đúng Service.
3. Tạo TLS Secret, gắn vào Ingress, curl HTTPS, verify cert.
4. Cài cert-manager, issue Let's Encrypt cert cho domain (hoặc self-signed CA cho lab).
5. Path-based routing: `/api` → backend, `/` → frontend, test.

## Checkpoint

- [ ] Giải thích được Ingress Controller watch Ingress resource và sinh config.
- [ ] Cài được ingress-nginx, routing host-based + path-based.
- [ ] Cấu hình được TLS termination.

---

# Phase 13 — Storage

> Thư mục: `phases/phase-13-storage/`

## Mục tiêu

Hiểu storage trong Kubernetes — từ PV/PVC static đến CSI dynamic provisioning. Biết chọn storage solution cho use case thực tế.

## Khái niệm cần nắm

- **PV (PersistentVolume)**: Cluster-level storage resource, provisioned bởi admin hoặc dynamic. Capacity, accessModes (RWO, ROX, RWX), reclaimPolicy (Retain, Delete, Recycle).
- **PVC (PersistentVolumeClaim)**: User request storage. Bind PVC → PV theo accessMode + capacity + storageClass. Pod reference PVC trong volume.
- **StorageClass**: Dynamic provisioning. `provisioner` field (CSI driver), `parameters` (disk type, replication), `volumeBindingMode` (`Immediate` vs `WaitForFirstConsumer`). Default StorageClass.
- **CSI (Container Storage Interface)**: gRPC interface giữa Kubernetes và storage driver. Identity service, Controller service (create/delete volume), Node service (mount/unmount). External provisioner/attacher/snapshotter.
- **NFS CSI**: CSI driver cho NFS share. Simple, good cho lab. `nfs-server` provisioner.
- **Longhorn**: Distributed block storage cho Kubernetes. Replica, snapshot, backup to S3. Good cho bare metal.
- **OpenEBS**: Container-attached storage. cStor (ZFS), Jiva (replicated), LocalPV. Good cho bare metal.
- **Ceph (tổng quan)**: RBD (block), CephFS (file), RGW (object). Rook operator deploy Ceph trên K8s. Production-grade.

## Thực hành

1. Tạo PV static (hostPath hoặc NFS), PVC bind, pod mount, ghi file, xóa pod, tạo pod mới mount lại — data còn.
2. Cài StorageClass + provisioner (Longhorn hoặc OpenEBS), tạo PVC, quan sát PV tự sinh.
3. Deploy StatefulSet với volumeClaimTemplate, quan sát mỗi pod có PVC riêng.
4. Snapshot PVC, restore từ snapshot, verify data.
5. Cài Longhorn, test replica failover — kill node, data vẫn available.

## Checkpoint

- [ ] Giải thích được flow: PVC → bind PV → pod mount → CSI driver attach.
- [ ] Dynamic provisioning thành công với StorageClass.
- [ ] Snapshot + restore PVC.
- [ ] Phân biệt RWO vs RWX, khi nào dùng cái nào.

---

# Phase 14 — Observability

> Thư mục: `phases/phase-14-observability/`

## Mục tiêu

Xây dựng stack observability đầy đủ: metrics (Prometheus + Grafana), logs (Loki), traces (Tempo), thu thập bằng OpenTelemetry.

## Khái niệm cần nắm

- **Metrics**: 4 loại metric (counter, gauge, histogram, summary). Prometheus scrape model (pull). kube-state-metrics, node-exporter, cAdvisor. PromQL cơ bản: `rate()`, `histogram_quantile()`, `sum by()`.
- **Logs**: Structured logging (JSON). Loki thay thế ELK — index label only, không index content. Promtail/Fluent Bit collect log, push Loki. LogQL query.
- **Traces**: Distributed tracing — trace, span, context propagation (W3C TraceContext). Tempo store trace, query bằng trace ID. Service map.
- **Prometheus**: Architecture — server (TSDB), scrape config, alerting rule, Alertmanager. ServiceMonitor (Prometheus Operator). Retention, federation.
- **Grafana**: Dashboard, datasource (Prometheus, Loki, Tempo), variable, panel type. Alerting.
- **Loki**: Label-based indexing, chunk storage. `logcli` query. Structured metadata.
- **Tempo**: Trace storage, TraceQL. Integration với Grafana service graph.
- **OpenTelemetry Collector**: Receiver (otlp, prometheus, loki), processor (batch, attributes), exporter (prometheus, loki, tempo). Agent mode vs gateway mode.

## Thực hành

1. Cài Prometheus + Grafana (kube-prometheus-stack helm chart), xem dashboard có sẵn (API Server, node, pod).
2. Viết PromQL: CPU usage per pod, memory usage per namespace, p99 latency.
3. Cài Loki + Promtail, query log trong Grafana: `{namespace="kube-system"} |= "error"`.
4. Instrument app (Python/Go) với OpenTelemetry SDK, send trace đến Tempo, xem trace trong Grafana.
5. Cài OpenTelemetry Collector, configure pipeline: receive OTLP → export Prometheus + Loki + Tempo.
6. Tạo Grafana alert: pod CPU > 80% trong 5 phút → alert.

## Checkpoint

- [ ] Cài được kube-prometheus-stack, xem dashboard có sẵn.
- [ ] Viết được PromQL query cơ bản.
- [ ] Query được log trong Loki qua Grafana.
- [ ] Generate trace từ app, xem trong Tempo/Grafana.
- [ ] Cấu hình được OTel Collector pipeline.

---

# Phase 15 — eBPF

> Thư mục: `phases/phase-15-ebpf/`

## Mục tiêu

Hiểu eBPF — công nghệ kernel cho phép chạy sandbox program trong kernel. Nắm cách Cilium dùng eBPF thay thế iptables/kube-proxy.

## Khái niệm cần nắm

- **eBPF Fundamentals**: eBPF = extended Berkeley Packet Filter. Chạy bytecode trong kernel, verified (safety), JIT compiled. Hook point: XDP, TC, socket, kprobe, tracepoint. Map (data sharing kernel ↔ userspace).
- **Cilium**: CNI dựa trên eBPF. Thay iptables cho network policy + service load balancing. eBPF program attach vào TC/XDP/socket. Cilium agent watch K8s API, generate BPF map, program đọc map.
- **Hubble**: Observability platform trên Cilium. Flow log (L4/L7), service dependency map, metrics. Hubble UI — visual network topology.
- **Socket Load Balancing**: eBPF program ở socket layer — intercept connect() syscall, redirect đến pod IP trực tiếp, bypass iptables. Faster than kube-proxy.
- **XDP (eXpress Data Path)**: eBPF program chạy ở driver layer, trước kernel network stack. DDoS mitigation, high-performance filtering.
- **kube-proxy Replacement**: Cilium eBPF thay toàn bộ kube-proxy. Service lookup + DNAT trong eBPF, không iptables rule. `kubeProxyReplacement=true`.

## Thực hành

1. Cài Cilium (without kube-proxy), verify cluster network hoạt động.
2. `cilium status`, `cilium monitor` — xem eBPF event realtime.
3. Mở Hubble UI, xem flow map giữa pod, filter theo namespace/verdict.
4. Tạo NetworkPolicy với Cilium, test deny/allow, xem Hubble flow log blocked.
5. So sánh performance: kube-proxy (iptables) vs Cilium (eBPF) — benchmark Service latency.
6. `kubectl -n kube-system exec ds/cilium -- cilium service list` — xem BPF service map.

## Checkpoint

- [ ] Giải thích được eBPF là gì, hook point nào Cilium dùng.
- [ ] Cài Cilium kube-proxy replacement, cluster hoạt động bình thường.
- [ ] Dùng Hubble xem flow, verify NetworkPolicy enforcement.
- [ ] So sánh được iptables vs eBPF performance.

---

# Phase 16 — kubeadm — Bootstrap & Quản lý Cluster

> Thư mục: `phases/phase-16-kubernetes-distributions/`

## Mục tiêu

Hiểu kubeadm đủ để bootstrap và vận hành cluster trong thực tế — biết nó tự động hóa những gì, và tự làm được bằng tay khi cần.

## Khái niệm cần nắm

- **kubeadm init**: Bootstrap control plane. Tự sinh CA + toàn bộ cert (API server, etcd, kubelet, scheduler, controller-manager), sinh kubeconfig, ghi static pod manifest cho etcd/apiserver/scheduler/controller-manager vào `/etc/kubernetes/manifests/`.
- **kubeadm join**: Join worker/control plane node. Dùng bootstrap token + TLS bootstrap, kubelet tự request CSR, kubeadm approve tự động.
- **kubeadm config**: `kubeadm config print init-defaults` / `join-defaults`. Customize ClusterConfiguration (CIDR, API server cert SAN, etcd endpoint). Config file YAML thay flag command line.
- **kubeadm upgrade**: `kubeadm upgrade plan` (check version), `kubeadm upgrade apply` (upgrade control plane), `kubeadm upgrade node` (upgrade worker). Rolling upgrade — upgrade master trước, worker sau.
- **kubeadm reset**: Cleanup node — xóa cert, kubeconfig, static pod, CNI config, iptables rule. Dùng khi join fail hoặc cần rebuild node.
- **Certificate Rotation**: `kubeadm certs renew` — renew tất cả cert. Cert mặc định hết hạn sau 1 năm. Cần restart control plane component sau renew.
- **kubeadm vs làm bằng tay**: kubeadm giấu: sinh cert, cấu hình etcd, static pod manifest, kubeconfig, RBAC cho kubelet. Hiểu từng bước để debug khi kubeadm fail.

## Thực hành

1. `kubeadm config print init-defaults > init.yaml`, chỉnh sửa: thêm API server cert SAN, đổi podCIDR/serviceCIDR, cấu hình etcd external.
2. `kubeadm init --config init.yaml`, kiểm tra cert sinh ra trong `/etc/kubernetes/pki/`, static pod manifest trong `/etc/kubernetes/manifests/`.
3. `kubeadm token create --print-join-command`, join 2 worker node, xem CSR `kubectl get csr`.
4. `kubeadm upgrade plan`, upgrade cluster lên minor version tiếp theo, quan sát rolling update static pod.
5. `kubeadm certs renew all`, kiểm tra cert mới, restart control plane component.
6. `kubeadm reset` trên 1 worker, cleanup, rejoin lại cluster.
7. So sánh: mở static pod manifest kubeadm sinh ra vs manifest tự viết ở Phase 4/7 — hiểu kubeadm giấu gì.

## Checkpoint

- [ ] Bootstrap được cluster bằng `kubeadm init` + `kubeadm join` với config file custom.
- [ ] Upgrade cluster lên version mới bằng `kubeadm upgrade`.
- [ ] Renew cert bằng `kubeadm certs renew`, restart component thành công.
- [ ] Giải thích được kubeadm tự động hóa những bước nào so với làm bằng tay ở các phase trước.

---

# Capstone — HA Kubernetes Cluster

> Thư mục: `capstone/`

## Mục tiêu

Tự dựng HA Kubernetes cluster từ đầu (không dùng kubeadm), cài đầy đủ addon, vận hành và debug.

## Yêu cầu kiến trúc

- **3 control plane node**: etcd cluster 3 node, kube-apiserver (load balancer phía trước), kube-scheduler, kube-controller-manager.
- **2 worker node**: kubelet + containerd + CNI.
- **Load balancer**: HAProxy/NGINX phía trước 3 API Server (keepalived VIP hoặc external LB).
- **Network**: Cilium (eBPF, kube-proxy replacement).
- **Ingress**: NGINX Ingress Controller + cert-manager.
- **Storage**: Longhorn (distributed block storage).
- **Monitoring**: kube-prometheus-stack (Prometheus + Grafana + Alertmanager).
- **Logging**: Loki + Promtail.
- **Tracing**: Tempo + OpenTelemetry Collector.

## Task checklist

- [ ] Sinh toàn bộ certificate (CA + tất cả component cert).
- [ ] Bootstrap etcd cluster 3 node với mTLS.
- [ ] Cấu hình HAProxy load balance 3 API Server.
- [ ] Chạy kube-apiserver trên 3 control plane node (static pod hoặc systemd).
- [ ] Chạy kube-controller-manager + kube-scheduler (leader election).
- [ ] Join 2 worker node bằng TLS bootstrap.
- [ ] Cài Cilium (kube-proxy replacement).
- [ ] Cài NGINX Ingress + cert-manager.
- [ ] Cài Longhorn, test PVC + replica failover.
- [ ] Cài kube-prometheus-stack, tạo dashboard custom.
- [ ] Cài Loki + Promtail, query log.
- [ ] Cài Tempo + OTel Collector, generate trace.
- [ ] Snapshot etcd, simulate disaster (xóa etcd data dir), restore.
- [ ] Debug scenario: pod CrashLoopBackOff, Service không có endpoint, NetworkPolicy block traffic, node NotReady.
- [ ] Viết runbook: bootstrap cluster từ đầu, restore etcd, rotate cert.

## Kết quả mong muốn

- Cluster 3 master + 2 worker HA, chạy ổn định.
- Toàn bộ addon (CNI, Ingress, CSI, monitoring, logging, tracing) hoạt động.
- Backup/restore etcd thành công.
- Debug được 4 scenario trên.
- Runbook đầy đủ để bootstrap lại cluster từ đầu.

---

# Kết quả mong muốn (overall)

Sau khi hoàn thành toàn bộ 17 phase + capstone:

- **Hiểu toàn bộ luồng hoạt động**: từ `kubectl apply` → API Server → etcd → controller → scheduler → kubelet → CRI → containerd → runc → kernel.
- **Debug ở mức hệ thống**: đọc `tcpdump`, `iptables-save`, `crictl`, `etcdctl`, `journalctl`, `strace` để tìm root cause.
- **Hiểu kubeadm**: biết chính xác kubeadm giấu những bước nào, tự làm được bằng tay khi cần.
- **Vận hành production**: backup/restore, cert rotation, upgrade, scaling, monitoring, incident response.
