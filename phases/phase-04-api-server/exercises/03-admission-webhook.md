# Exercise 03 — ValidatingAdmissionWebhook

> **Mục tiêu**: Enable admission webhook, viết một ValidatingAdmissionWebhook từ chối pod không có label `app`.
>
> **Thời gian dự kiến**: 40 phút
>
> **Yêu cầu**: Kubernetes cluster đang chạy (kubeadm hoặc exercise 01), `kubectl` admin access

## Bối cảnh

Admission webhook cho phép external service tham gia admission pipeline. Bài này viết một simple webhook server bằng Python, deploy vào cluster, cấu hình ValidatingWebhookConfiguration để enforce: pod phải có label `app`.

## Bước 1: Viết webhook server

Tạo file `webhook-server.py`:

```python
#!/usr/bin/env python3
"""Validating admission webhook — require pod label 'app'."""

import json
import ssl
from http.server import HTTPServer, BaseHTTPRequestHandler

class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length)
        admission_review = json.loads(body)

        uid = admission_review['request']['uid']
        kind = admission_review['request']['kind']['kind']
        operation = admission_review['request']['operation']

        # Only validate CREATE and UPDATE pod
        if kind != 'Pod' or operation not in ('CREATE', 'UPDATE'):
            self._respond(uid, True, "skipped: not a pod create/update")
            return

        pod = admission_review['request']['object']
        labels = pod.get('metadata', {}).get('labels', {})
        app_label = labels.get('app')

        if app_label:
            self._respond(uid, True, f"allowed: pod has label app={app_label}")
        else:
            self._respond(uid, False, "denied: pod must have label 'app'")

    def _respond(self, uid, allowed, message):
        response = {
            "apiVersion": "admission.k8s.io/v1",
            "kind": "AdmissionReview",
            "response": {
                "uid": uid,
                "allowed": allowed,
                "status": {
                    "message": message
                }
            }
        }
        body = json.dumps(response).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        print(f"[webhook] {args[0]}")

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', 8443), WebhookHandler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain('/etc/webhook/cert.pem', '/etc/webhook/key.pem')
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print("[webhook] Listening on :8443")
    server.serve_forever()
```

> Webhook nhận `AdmissionReview` request, kiểm tra pod có label `app` không, trả về allow/deny.

## Bước 2: Tạo cert cho webhook

API Server gọi webhook qua HTTPS — webhook cần TLS cert. Cert phải được ký bởi CA mà API Server trust.

```bash
# Tạo CA cho webhook
openssl genrsa -out /tmp/webhook-ca-key.pem 2048
openssl req -new -x509 -key /tmp/webhook-ca-key.pem -out /tmp/webhook-ca.pem \
  -subj "/CN=webhook-ca" -days 365

# Tạo CSR cho webhook server
openssl genrsa -out /tmp/webhook-key.pem 2048
openssl req -new -key /tmp/webhook-key.pem -out /tmp/webhook.csr \
  -subj "/CN=admission-webhook.kube-system.svc"

# Tạo SAN extension
cat > /tmp/webhook-ext.cnf << 'EOF'
[req]
distinguished_name = req
[v3_ext]
subjectAltName = DNS:admission-webhook.kube-system.svc,DNS:admission-webhook.kube-system.svc.cluster.local
EOF

# Ký cert
openssl x509 -req -in /tmp/webhook.csr \
  -CA /tmp/webhook-ca.pem \
  -CAkey /tmp/webhook-ca-key.pem \
  -CAcreateserial -out /tmp/webhook-cert.pem \
  -days 365 -extensions v3_ext -extfile /tmp/webhook-ext.cnf

# Verify
openssl verify -CAfile /tmp/webhook-ca.pem /tmp/webhook-cert.pem
# /tmp/webhook-cert.pem: OK
```

> SAN phải chứa Service DNS name: `admission-webhook.kube-system.svc` — API Server gọi webhook qua Service.

**Kiểm tra**: `openssl verify` trả về OK.

## Bước 3: Tạo Kubernetes Secret chứa cert

```bash
# Tạo namespace kube-system nếu chưa có
kubectl create namespace kube-system 2>/dev/null || true

# Tạo Secret chứa webhook cert
kubectl create secret generic webhook-tls \
  --from-file=cert.pem=/tmp/webhook-cert.pem \
  --from-file=key.pem=/tmp/webhook-key.pem \
  -n kube-system
```

## Bước 4: Deploy webhook server

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: admission-webhook
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: admission-webhook
  template:
    metadata:
      labels:
        app: admission-webhook
    spec:
      containers:
      - name: webhook
        image: python:3.12-slim
        command: ["python3", "/app/webhook-server.py"]
        ports:
        - containerPort: 8443
        volumeMounts:
        - name: webhook-code
          mountPath: /app
        - name: webhook-tls
          mountPath: /etc/webhook
          readOnly: true
      volumes:
      - name: webhook-code
        configMap:
          name: webhook-code
      - name: webhook-tls
        secret:
          secretName: webhook-tls
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: webhook-code
  namespace: kube-system
data:
  webhook-server.py: |
    #!/usr/bin/env python3
    """Validating admission webhook — require pod label 'app'."""
    import json
    import ssl
    from http.server import HTTPServer, BaseHTTPRequestHandler

    class WebhookHandler(BaseHTTPRequestHandler):
        def do_POST(self):
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length)
            admission_review = json.loads(body)
            uid = admission_review['request']['uid']
            kind = admission_review['request']['kind']['kind']
            operation = admission_review['request']['operation']
            if kind != 'Pod' or operation not in ('CREATE', 'UPDATE'):
                self._respond(uid, True, "skipped")
                return
            pod = admission_review['request']['object']
            labels = pod.get('metadata', {}).get('labels', {})
            app_label = labels.get('app')
            if app_label:
                self._respond(uid, True, f"allowed: app={app_label}")
            else:
                self._respond(uid, False, "denied: pod must have label 'app'")

        def _respond(self, uid, allowed, message):
            response = {
                "apiVersion": "admission.k8s.io/v1",
                "kind": "AdmissionReview",
                "response": {
                    "uid": uid,
                    "allowed": allowed,
                    "status": {"message": message}
                }
            }
            body = json.dumps(response).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', len(body))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            print(f"[webhook] {args[0]}")

    if __name__ == '__main__':
        server = HTTPServer(('0.0.0.0', 8443), WebhookHandler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain('/etc/webhook/cert.pem', '/etc/webhook/key.pem')
        server.socket = context.wrap_socket(server.socket, server_side=True)
        print("[webhook] Listening on :8443")
        server.serve_forever()
---
apiVersion: v1
kind: Service
metadata:
  name: admission-webhook
  namespace: kube-system
spec:
  selector:
    app: admission-webhook
  ports:
  - port: 443
    targetPort: 8443
EOF
```

**Kiểm tra**: Pod `admission-webhook` running, Service `admission-webhook` tồn tại.

```bash
kubectl get pods -n kube-system -l app=admission-webhook
# NAME                                 READY   STATUS    RESTARTS   AGE
# admission-webhook-xxx                1/1     Running   0          30s

kubectl get svc -n kube-system admission-webhook
# NAME               TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
# admission-webhook  ClusterIP   10.96.100.50    <none>        443/TCP   30s
```

## Bước 5: Tạo ValidatingWebhookConfiguration

```bash
# Encode CA cert để put vào webhook config
WEBHOOK_CA_BUNDLE=$(base64 -w0 /tmp/webhook-ca.pem)

cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: require-app-label
webhooks:
- name: require-app-label.example.com
  clientConfig:
    service:
      name: admission-webhook
      namespace: kube-system
      path: /validate
    caBundle: ${WEBHOOK_CA_BUNDLE}
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE", "UPDATE"]
    resources: ["pods"]
  failurePolicy: Fail
  sideEffects: None
  admissionReviewVersions: ["v1"]
EOF
```

> `caBundle` = base64-encoded CA cert. API Server dùng CA này để verify webhook server cert.

**Kiểm tra**: `kubectl get validatingwebhookconfiguration require-app-label` tồn tại.

## Bước 6: Test — pod KHÔNG có label `app` → bị reject

```bash
# Tạo pod không có label app
kubectl run test-no-label --image=nginx -n default
# Error from server: admission webhook "require-app-label.example.com" denied the request: denied: pod must have label 'app'
```

> Webhook deny request — pod không có label `app`.

**Kiểm tra**: `kubectl run` fail với message `denied: pod must have label 'app'`.

## Bước 7: Test — pod CÓ label `app` → được accept

```bash
# Tạo pod có label app
kubectl run test-with-label --image=nginx -n default --labels=app=test
# pod/test-with-label created

# Verify
kubectl get pods -n default -l app=test
# NAME               READY   STATUS    RESTARTS   AGE
# test-with-label    1/1     Running   0          5s
```

> Webhook allow request — pod có label `app=test`.

**Kiểm tra**: Pod `test-with-label` created thành công.

## Bước 8: Test — deployment không có label app

```bash
# Deployment template không có label app
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy-no-label
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      foo: bar
  template:
    metadata:
      labels:
        foo: bar
    spec:
      containers:
      - name: nginx
        image: nginx
EOF
# Error from server: admission webhook "require-app-label.example.com" denied the request: denied: pod must have label 'app'
```

> Webhook validate pod template — deployment không có label `app` trong pod template → reject.

## Bước 9: Xem webhook log

```bash
kubectl logs -n kube-system -l app=admission-webhook --tail=20
# [webhook] POST /validate
# [webhook] POST /validate
# [webhook] denied: pod must have label 'app'
# [webhook] allowed: app=test
```

## Bước 10: Cleanup webhook

```bash
# Xóa ValidatingWebhookConfiguration
kubectl delete validatingwebhookconfiguration require-app-label

# Xóa webhook deployment
kubectl delete deployment admission-webhook -n kube-system
kubectl delete service admission-webhook -n kube-system
kubectl delete configmap webhook-code -n kube-system
kubectl delete secret webhook-tls -n kube-system

# Xóa test pods
kubectl delete pod test-with-label -n default --force 2>/dev/null || true
```

> **Quan trọng**: Xóa ValidatingWebhookConfiguration trước khi xóa webhook deployment — nếu không, webhook down + `failurePolicy: Fail` → không tạo pod được.

## Câu hỏi tự kiểm tra

1. Tại sao Mutating admission chạy trước Validating admission?
2. `failurePolicy: Fail` vs `Ignore` — khi nào dùng cái nào?
3. Tại sao webhook cần TLS cert? API Server gọi webhook qua gì?
4. Nếu webhook server down, điều gì xảy ra với `failurePolicy: Fail`?
5. Tại sao xóa ValidatingWebhookConfiguration trước khi xóa webhook deployment?

## Đáp án tham khảo

1. Mutating sửa request (add default, inject sidecar). Validating kiểm tra **final result** sau mutation. Nếu Validating trước, mutation sau có thể vi phạm rule mà Validating đã pass.
2. `Fail` — request bị reject nếu webhook down. Dùng cho security policy (strict). `Ignore` — request tiếp tục nếu webhook down. Dùng cho non-critical mutation (sidecar injection).
3. API Server gọi webhook qua HTTPS (Service ClusterIP). TLS cert đảm bảo API Server nói chuyện đúng webhook, không bị MITM. `caBundle` trong webhook config = CA để API Server verify webhook cert.
4. Mọi pod create/update bị reject (403 Forbidden) — webhook không respond, `failurePolicy: Fail` = deny. Cluster không tạo pod được → phải xóa webhook config hoặc restore webhook.
5. Nếu xóa deployment trước, webhook down. `failurePolicy: Fail` → mọi pod create/update bị reject. Xóa webhook config trước → admission pipeline không gọi webhook nữa → an toàn xóa deployment.
