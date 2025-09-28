#!/usr/bin/env bash
set -euo pipefail

cat <<'EOCMD'
sudo bash -s <<'EOSCRIPT'
set -euo pipefail

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Required command '$1' not found. Install it before running." >&2
    exit 1
  fi
}

for bin in curl openssl sed awk tee; do
  require "$bin"
done

prompt_required() {
  local var="$1" msg="$2"
  local val
  while true; do
    read -r -p "$msg" val
    if [[ -n "$val" ]]; then
      printf -v "$var" '%s' "$val"
      export "$var"
      break
    else
      echo "Value cannot be empty" >&2
    fi
  done
}

prompt_default() {
  local var="$1" msg="$2" def="$3"
  local val
  read -r -p "$msg" val
  if [[ -z "$val" ]]; then
    val="$def"
  fi
  printf -v "$var" '%s' "$val"
  export "$var"
}

prompt_required ACME_EMAIL "Enter ACME email for Let's Encrypt: "
prompt_default DOMAIN_MODE "Domain mode (sslip.io/custom) [sslip.io]: " "sslip.io"

if [[ "$DOMAIN_MODE" != "sslip.io" && "$DOMAIN_MODE" != "custom" ]]; then
  echo "Invalid domain mode" >&2
  exit 1
fi

PUBLIC_IP="$(curl -sf https://api.ipify.org || curl -sf https://ifconfig.me || hostname -I | awk '{print $1}')"
if [[ -z "$PUBLIC_IP" ]]; then
  echo "Unable to determine public IP address" >&2
  exit 1
fi

if [[ "$DOMAIN_MODE" == "sslip.io" ]]; then
  HOST_SUFFIX="${PUBLIC_IP}.sslip.io"
  HOST_SITE="site.${HOST_SUFFIX}"
  HOST_TEST="test.${HOST_SUFFIX}"
  HOST_ARGO="argo.${HOST_SUFFIX}"
  HOST_GRAFANA="grafana.${HOST_SUFFIX}"
  HOST_LOGS="logs.${HOST_SUFFIX}"
  HOST_TRACE="trace.${HOST_SUFFIX}"
else
  prompt_required HOST_SITE "Enter hostname for PROD site: "
  prompt_required HOST_TEST "Enter hostname for TEST site: "
  prompt_required HOST_ARGO "Enter hostname for Argo CD: "
  prompt_required HOST_GRAFANA "Enter hostname for Grafana: "
  prompt_required HOST_LOGS "Enter hostname for OpenSearch Dashboards: "
  prompt_required HOST_TRACE "Enter hostname for tracing UI: "
  echo "--- Host summary ---" >&2
  printf ' PROD  : %s
' "$HOST_SITE" >&2
  printf ' TEST  : %s
' "$HOST_TEST" >&2
  printf ' Argo  : %s
' "$HOST_ARGO" >&2
  printf ' Grafana: %s
' "$HOST_GRAFANA" >&2
  printf ' Logs  : %s
' "$HOST_LOGS" >&2
  printf ' Trace : %s
' "$HOST_TRACE" >&2
  read -r -p "Continue with these hostnames? (y/N): " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted by user" >&2
    exit 1
  fi
fi

prompt_default RETENTION_LOGS "Log retention days [7]: " "7"
prompt_default RETENTION_METRICS "Metrics retention days [15]: " "15"
prompt_default SERVER_SIZE "Server size (small/medium/large) [small]: " "small"
prompt_default INSTALL_KAFKA "Install Kafka (y/N)? " "N"
prompt_default ALERT_MODE "Alerting mode (telegram/email/skip) [skip]: " "skip"

case "$ALERT_MODE" in
  telegram)
    prompt_required TELEGRAM_BOT_TOKEN "Enter Telegram bot token: "
    prompt_required TELEGRAM_CHAT_ID "Enter Telegram chat id: "
    ;;
  email)
    prompt_required SMTP_HOST "SMTP host: "
    prompt_required SMTP_PORT "SMTP port: "
    prompt_required SMTP_USER "SMTP user: "
    prompt_required SMTP_PASS "SMTP password: "
    prompt_required ALERT_EMAIL_TO "Alert recipient: "
    prompt_required ALERT_EMAIL_FROM "Alert sender: "
    ;;
  skip)
    ;;
  *)
    echo "Invalid alert mode" >&2
    exit 1
    ;;
esac

prompt_default S3_ENDPOINT "S3 endpoint (empty for AWS): " ""
prompt_required S3_REGION "S3 region: "
prompt_required S3_BUCKET "S3 bucket: "
prompt_required S3_ACCESS_KEY "S3 access key: "
prompt_required S3_SECRET_KEY "S3 secret key: "

mkdir -p /tmp/k3s-bootstrap

if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow 80/tcp || true
  sudo ufw allow 443/tcp || true
fi

if ! systemctl is-active --quiet k3s; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode=644" sh -
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

for ns in argocd test prod observability logging tracing backups security kyverno; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

kubectl get namespace cert-manager >/dev/null 2>&1 || kubectl create namespace cert-manager
kubectl get namespace ingress-nginx >/dev/null 2>&1 || kubectl create namespace ingress-nginx

if ! kubectl get deploy -n ingress-nginx ingress-nginx-controller >/dev/null 2>&1; then
  curl -sSL https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml     | sed 's/LoadBalancer/NodePort/g'     | kubectl apply -f -
fi

kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=10m

if ! kubectl get deploy -n cert-manager cert-manager >/dev/null 2>&1; then
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
fi

kubectl -n cert-manager rollout status deployment/cert-manager --timeout=10m
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=10m
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=10m

cat <<'EOISSUER' | envsubst | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-http
spec:
  acme:
    email: ${ACME_EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-http
    solvers:
      - http01:
          ingress:
            class: nginx
EOISSUER

ARGO_VERSION="v2.9.4"
if ! kubectl get deploy -n argocd argocd-server >/dev/null 2>&1; then
  kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_VERSION}/manifests/install.yaml"
fi

kubectl -n argocd rollout status deployment/argocd-server --timeout=10m

if ! command -v helm >/dev/null 2>&1; then
  curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add opensearch https://opensearch-project.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add fluent https://fluent.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

apply_ingress() {
  local name="$1" namespace="$2" host="$3" svc="$4" port="$5" tlsSecret="$6" extra="$7" annotations="$8"
  cat <<EOI | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${name}
  namespace: ${namespace}
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/hsts: "true"
    nginx.ingress.kubernetes.io/hsts-max-age: "31536000"
    nginx.ingress.kubernetes.io/proxy-body-size: "32m"
    nginx.ingress.kubernetes.io/server-snippet: |
      add_header Content-Security-Policy "default-src 'self'; connect-src 'self' https:; img-src 'self' data: https:; style-src 'self' 'unsafe-inline'; script-src 'self'; frame-ancestors 'none';" always;
      add_header Referrer-Policy strict-origin-when-cross-origin always;
      add_header X-Content-Type-Options nosniff always;
      add_header X-Frame-Options SAMEORIGIN always;
      add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
      gzip on;
      gzip_types text/plain text/css application/json application/javascript application/xml;
${annotations}
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${host}
      secretName: ${tlsSecret}
  rules:
    - host: ${host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${svc}
                port:
                  number: ${port}
${extra}
EOI
}

apply_ingress argocd argocd "$HOST_ARGO" argocd-server 443 argocd-tls "" "    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS""

rand_secret() {
  openssl rand -hex 16
}

create_pg() {
  local namespace="$1" release="$2" secret="$3"
  local password
  password="$(kubectl -n "$namespace" get secret "$secret" -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d || rand_secret)"
  kubectl -n "$namespace" create secret generic "$secret"     --from-literal=postgres-password="$password"     --from-literal=password="$password"     --from-literal=postgres-root-password="$password"     --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install "$release" oci://registry-1.docker.io/bitnamicharts/postgresql     --namespace "$namespace"     --set global.postgresql.auth.database=appdb     --set global.postgresql.auth.username=app     --set global.postgresql.auth.existingSecret="$secret"     --set primary.persistence.size=10Gi     --set volumePermissions.enabled=true     --wait --timeout 15m
}

create_pg prod postgres-prod app-postgres-prod
create_pg test postgres-test app-postgres-test

wait_rollout() {
  local ns="$1" kind="$2" name="$3"
  kubectl -n "$ns" rollout status "$kind"/"$name" --timeout=10m || true
}

wait_rollout prod statefulset postgres-prod-postgresql
wait_rollout test statefulset postgres-test-postgresql

create_static_site() {
  local namespace="$1" name="$2" robots="$3" host="$4"
  kubectl -n "$namespace" create configmap "${name}-content"     --from-literal=index.html="<!DOCTYPE html><html><head><meta charset='utf-8'><title>${name^}</title></head><body><main><h1>${name^} environment</h1><p>Everything is up.</p></main></body></html>"     --from-literal=robots.txt="$robots"     --from-literal=sitemap.xml="<?xml version='1.0' encoding='UTF-8'?><urlset xmlns='http://www.sitemaps.org/schemas/sitemap/0.9'><url><loc>https://${host}/</loc></url></urlset>"     --dry-run=client -o yaml | kubectl apply -f -

  cat <<EOFDEP | kubectl apply -n "$namespace" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}-web
  labels:
    app: ${name}-web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${name}-web
  template:
    metadata:
      labels:
        app: ${name}-web
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
      containers:
        - name: nginx
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 300m
              memory: 256Mi
      volumes:
        - name: html
          configMap:
            name: ${name}-content
EOFDEP

  cat <<EOFECHO | kubectl apply -n "$namespace" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}-api
  labels:
    app: ${name}-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}-api
  template:
    metadata:
      labels:
        app: ${name}-api
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
        - name: echo
          image: ealen/echo-server:0.8.10
          env:
            - name: PORT
              value: "8080"
          ports:
            - containerPort: 8080
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
EOFECHO

  kubectl -n "$namespace" apply -f - <<EOSVC
apiVersion: v1
kind: Service
metadata:
  name: ${name}-web
spec:
  selector:
    app: ${name}-web
  ports:
    - name: http
      port: 80
      targetPort: 80
EOSVC

  kubectl -n "$namespace" apply -f - <<EOSVC
apiVersion: v1
kind: Service
metadata:
  name: ${name}-api
spec:
  selector:
    app: ${name}-api
  ports:
    - name: http
      port: 80
      targetPort: 8080
EOSVC
}

create_static_site prod prod "User-agent: *
Allow: /" "$HOST_SITE"
create_static_site test test "User-agent: *
Disallow: /" "$HOST_TEST"

apply_ingress prod-site prod "$HOST_SITE" prod-web 80 prod-site-tls "          - path: /api
            pathType: Prefix
            backend:
              service:
                name: prod-api
                port:
                  number: 80" ""

apply_ingress test-site test "$HOST_TEST" test-web 80 test-site-tls "          - path: /api
            pathType: Prefix
            backend:
                service:
                  name: test-api
                  port:
                    number: 80" ""

cat <<EOF > /tmp/k3s-bootstrap/kube-prometheus-values.yaml
alertmanager:
  config:
    global:
      resolve_timeout: 5m
$(if [[ "$ALERT_MODE" == telegram ]]; then cat <<EOT
    route:
      receiver: telegram
    receivers:
      - name: telegram
        telegram_configs:
          - bot_token: "${TELEGRAM_BOT_TOKEN}"
            chat_id: "${TELEGRAM_CHAT_ID}"
EOT
elif [[ "$ALERT_MODE" == email ]]; then cat <<EOT
    route:
      receiver: email
    receivers:
      - name: email
        email_configs:
          - to: "${ALERT_EMAIL_TO}"
            from: "${ALERT_EMAIL_FROM}"
            smarthost: "${SMTP_HOST}:${SMTP_PORT}"
            auth_username: "${SMTP_USER}"
            auth_password: "${SMTP_PASS}"
            require_tls: true
EOT
else cat <<'EOT'
    route:
      receiver: devnull
    receivers:
      - name: devnull
EOT
fi)
prometheus:
  prometheusSpec:
    retention: ${RETENTION_METRICS}d
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi
grafana:
  enabled: true
  grafana.ini:
    server:
      root_url: https://${HOST_GRAFANA}
      domain: ${HOST_GRAFANA}
  persistence:
    enabled: true
    size: 5Gi
  ingress:
    enabled: false
EOF

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack   -n observability   -f /tmp/k3s-bootstrap/kube-prometheus-values.yaml   --set grafana.service.type=ClusterIP   --wait --timeout 20m

apply_ingress grafana observability "$HOST_GRAFANA" kube-prometheus-stack-grafana 80 grafana-tls "" ""

cat <<EOF > /tmp/k3s-bootstrap/opensearch-values.yaml
singleNode: true
persistence:
  size: 20Gi
resources:
  requests:
    cpu: 200m
    memory: 1Gi
  limits:
    cpu: 1
    memory: 4Gi
config:
  opensearch.yml: |
    plugins.security.disabled: true
    cluster.routing.allocation.disk.threshold_enabled: false
EOF

helm upgrade --install opensearch opensearch/opensearch -n logging -f /tmp/k3s-bootstrap/opensearch-values.yaml --wait --timeout 20m

cat <<EOF > /tmp/k3s-bootstrap/opensearch-dashboards-values.yaml
opensearchHosts: "https://opensearch-master.logging.svc.cluster.local:9200"
service:
  type: ClusterIP
persistence:
  enabled: true
  size: 5Gi
EOF

helm upgrade --install opensearch-dashboards opensearch/opensearch-dashboards -n logging -f /tmp/k3s-bootstrap/opensearch-dashboards-values.yaml --wait --timeout 15m

apply_ingress logs logging "$HOST_LOGS" opensearch-dashboards 5601 logs-tls "" ""

cat <<EOF > /tmp/k3s-bootstrap/fluent-bit-values.yaml
serviceAccount:
  create: true
config:
  service:
    flush: 1
    log_level: info
  inputs:
    tail.conf: |
      [INPUT]
          Name tail
          Path /var/log/containers/*.log
          multiline.parser docker
          Tag kube.*
          Mem_Buf_Limit 5MB
          Skip_Long_Lines On
  filters:
    kubernetes.conf: |
      [FILTER]
          Name kubernetes
          Match kube.*
          Kube_URL https://kubernetes.default.svc:443
          Kube_Tag_Prefix kube.var.log.containers.
          Merge_Log On
          Keep_Log Off
          Labels On
          Annotations Off
  outputs:
    opensearch.conf: |
      [OUTPUT]
          Name  es
          Match *
          Host  opensearch-master.logging.svc.cluster.local
          Port  9200
          HTTPS On
          tls.verify Off
          Index fluentbit
          Logstash_Format On
          Replace_Dots On
          Retry_Limit False
EOF

helm upgrade --install fluent-bit fluent/fluent-bit -n logging -f /tmp/k3s-bootstrap/fluent-bit-values.yaml --wait --timeout 10m

helm upgrade --install tempo jaegertracing/jaeger -n tracing   --set provisionDataStore.cassandra=false   --set provisionDataStore.elasticsearch=false   --set storage.type=memory   --wait --timeout 10m

apply_ingress trace tracing "$HOST_TRACE" jaeger-query 16686 trace-tls "" ""

cat <<EOF > /tmp/k3s-bootstrap/velero-values.yaml
configuration:
  provider: aws
  backupStorageLocation:
    name: default
    bucket: ${S3_BUCKET}
    config:
      region: ${S3_REGION}
$(if [[ -n "$S3_ENDPOINT" ]]; then printf '      s3Url: %s
' "$S3_ENDPOINT"; fi)
  volumeSnapshotLocation:
    name: default
    config:
      region: ${S3_REGION}
credentials:
  useSecret: true
  secretContents:
    cloud: |
      [default]
      aws_access_key_id=${S3_ACCESS_KEY}
      aws_secret_access_key=${S3_SECRET_KEY}
initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.6.0
    volumeMounts:
      - mountPath: /target
        name: plugins
schedules:
  daily:
    schedule: "0 3 * * *"
    template:
      ttl: 168h
EOF

helm upgrade --install velero vmware-tanzu/velero -n backups -f /tmp/k3s-bootstrap/velero-values.yaml --set configuration.backupStorageLocation.config.s3ForcePathStyle=true --wait --timeout 15m

cat <<'EOFNP' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
EOFNP

cat <<'EOFNP' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prod-web
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: prod-web
  ingress:
    - from: []
      ports:
        - port: 80
  egress:
    - to: []
      ports:
        - port: 53
          protocol: UDP
EOFNP

if ! kubectl get deploy -n kyverno kyverno >/dev/null 2>&1; then
  kubectl apply -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml
fi
kubectl -n kyverno rollout status deployment/kyverno --timeout=10m

cat <<'EOCPOL' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged
spec:
  validationFailureAction: enforce
  background: true
  rules:
    - name: check-privileged
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: Privileged containers are not allowed.
        pattern:
          spec:
            containers:
              - =(securityContext):
                  =(privileged): false
EOCPOL

cat <<'EOCPOL' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-runasnonroot
spec:
  validationFailureAction: enforce
  background: true
  rules:
    - name: run-as-non-root
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: Containers must set runAsNonRoot true.
        pattern:
          spec:
            securityContext:
              runAsNonRoot: true
EOCPOL

for ns in argocd prod test observability logging tracing; do
  for cert in $(kubectl -n "$ns" get certificates.cert-manager.io -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl -n "$ns" wait certificate "$cert" --for=condition=Ready --timeout=15m || true
  done
done

ARGO_PWD="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo 'N/A')"
POSTGRES_PASSWORD_PROD="$(kubectl -n prod get secret app-postgres-prod -o jsonpath='{.data.postgres-password}' | base64 -d)"
POSTGRES_PASSWORD_TEST="$(kubectl -n test get secret app-postgres-test -o jsonpath='{.data.postgres-password}' | base64 -d)"

cat <<EOR
========================================
Public endpoints:
  Argo CD : https://${HOST_ARGO}
  Grafana : https://${HOST_GRAFANA}
  Logs    : https://${HOST_LOGS}
  Trace   : https://${HOST_TRACE}
  PROD    : https://${HOST_SITE}
  TEST    : https://${HOST_TEST}

Credentials:
  Argo CD admin password: ${ARGO_PWD}
  PostgreSQL PROD DSN: postgresql://app:${POSTGRES_PASSWORD_PROD}@postgres-prod-postgresql.prod.svc.cluster.local:5432/appdb
  PostgreSQL TEST DSN: postgresql://app:${POSTGRES_PASSWORD_TEST}@postgres-test-postgresql.test.svc.cluster.local:5432/appdb

Health checks:
  curl -k https://${HOST_SITE}/api/health
  curl -k https://${HOST_TEST}/api/health
  kubectl get pods -A
  kubectl get ingress -A

To change domains later:
  kubectl patch ingress <name> -n <namespace> --type merge -p '{"spec":{"rules":[{"host":"new.host"}]}}' && certificates will renew automatically.
========================================
EOR
EOSCRIPT
EOCMD
