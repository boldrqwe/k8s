#!/usr/bin/env bash
set -euo pipefail

main() {
  ensure_root "$@"
  ensure_requirements
  collect_inputs
  prepare_directories
  open_firewall
  install_k3s_if_missing
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  create_namespaces
  install_ingress
  install_cert_manager
  install_cluster_issuer
  install_argocd
  install_helm_if_missing
  add_helm_repositories
  ensure_postgres_secrets
  apply_argocd_applications
  wait_for_applications
  wait_for_certificates
  print_summary
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
  fi
}

ensure_requirements() {
  local bins=(curl openssl sed awk tee envsubst)
  for bin in "${bins[@]}"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "[ERROR] Required command '$bin' not found. Install it before running." >&2
      exit 1
    fi
  done
}

prompt_required() {
  local var="$1" msg="$2" val
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
  local var="$1" msg="$2" def="$3" val
  read -r -p "$msg" val
  if [[ -z "$val" ]]; then
    val="$def"
  fi
  printf -v "$var" '%s' "$val"
  export "$var"
}

detect_repo_defaults() {
  local script_dir repo_root repo_url repo_revision
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if git -C "${script_dir}/.." rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repo_url="$(git -C "${script_dir}/.." config --get remote.origin.url 2>/dev/null || true)"
    repo_revision="$(git -C "${script_dir}/.." rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
    printf '%s %s' "$repo_url" "$repo_revision"
  else
    printf ' '
  fi
}

collect_inputs() {
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
    HOST_DASHBOARD="k8s.${HOST_SUFFIX}"
  else
    prompt_required HOST_SITE "Enter hostname for PROD site: "
    prompt_required HOST_TEST "Enter hostname for TEST site: "
    prompt_required HOST_ARGO "Enter hostname for Argo CD: "
    prompt_required HOST_GRAFANA "Enter hostname for Grafana: "
    prompt_required HOST_LOGS "Enter hostname for OpenSearch Dashboards: "
    prompt_required HOST_TRACE "Enter hostname for tracing UI: "
    prompt_required HOST_DASHBOARD "Enter hostname for Kubernetes dashboard: "
    echo "--- Host summary ---" >&2
    printf ' PROD  : %s\n' "$HOST_SITE" >&2
    printf ' TEST  : %s\n' "$HOST_TEST" >&2
    printf ' Argo  : %s\n' "$HOST_ARGO" >&2
    printf ' Grafana: %s\n' "$HOST_GRAFANA" >&2
    printf ' Logs  : %s\n' "$HOST_LOGS" >&2
    printf ' Trace : %s\n' "$HOST_TRACE" >&2
    printf ' K8s   : %s\n' "$HOST_DASHBOARD" >&2
    read -r -p "Continue with these hostnames? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
      echo "Aborted by user" >&2
      exit 1
    fi
  fi

  prompt_default RETENTION_METRICS "Metrics retention days [15]: " "15"
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
}

prepare_directories() {
  INSTALL_ROOT=/tmp/k3s-bootstrap
  mkdir -p "$INSTALL_ROOT"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
  fi
}

install_k3s_if_missing() {
  if ! systemctl is-active --quiet k3s; then
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode=644" sh -
  fi
}

create_namespaces() {
  local namespaces=(argocd test prod observability logging tracing backups security kyverno kubernetes-dashboard)
  for ns in "${namespaces[@]}"; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
  kubectl get namespace cert-manager >/dev/null 2>&1 || kubectl create namespace cert-manager
  kubectl get namespace ingress-nginx >/dev/null 2>&1 || kubectl create namespace ingress-nginx
}

install_ingress() {
  if ! kubectl get deploy -n ingress-nginx ingress-nginx-controller >/dev/null 2>&1; then
    curl -sSL https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml | kubectl apply -f -
  fi
  kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=10m
}

install_cert_manager() {
  if ! kubectl get deploy -n cert-manager cert-manager >/dev/null 2>&1; then
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
  fi
  kubectl -n cert-manager rollout status deployment/cert-manager --timeout=10m
  kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=10m
  kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=10m
}

install_cluster_issuer() {
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
}

install_argocd() {
  local ARGO_VERSION="v2.9.4"
  if ! kubectl get deploy -n argocd argocd-server >/dev/null 2>&1; then
    kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_VERSION}/manifests/install.yaml"
  fi
  kubectl -n argocd rollout status deployment/argocd-server --timeout=10m
  apply_ingress argocd argocd "$HOST_ARGO" argocd-server 443 argocd-tls "" "" "" "nginx.ingress.kubernetes.io/backend-protocol: \"HTTPS\""
}

install_helm_if_missing() {
  if ! command -v helm >/dev/null 2>&1; then
    curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
}

add_helm_repositories() {
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add opensearch https://opensearch-project.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add fluent https://fluent.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
  helm repo add jaegertracing https://jaegertracing.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add kyverno https://kyverno.github.io/kyverno >/dev/null 2>&1 || true
  helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1
}

rand_secret() {
  openssl rand -hex 16
}

ensure_postgres_secrets() {
  ensure_pg_secret prod app-postgres-prod
  ensure_pg_secret test app-postgres-test
}

ensure_pg_secret() {
  local namespace="$1" secret="$2" password
  password="$(kubectl -n "$namespace" get secret "$secret" -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d || rand_secret)"
  kubectl -n "$namespace" create secret generic "$secret" \
    --from-literal=postgres-password="$password" \
    --from-literal=password="$password" \
    --from-literal=postgres-root-password="$password" \
    --dry-run=client -o yaml | kubectl apply -f -
}

apply_argocd_applications() {
  local alert_block
  alert_block="$(alert_config | sed 's/^/      /')"

  kubectl apply -n argocd -f - <<EOF
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: postgres-prod
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: prod
  source:
    repoURL: https://charts.bitnami.com/bitnami
    chart: postgresql
    targetRevision: 16.7.27
    helm:
      values: |
        global:
          postgresql:
            auth:
              database: appdb
              username: app
              existingSecret: app-postgres-prod
        primary:
          persistence:
            size: 10Gi
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
          podSecurityContext:
            enabled: true
        volumePermissions:
          enabled: true
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: postgres-test
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: test
  source:
    repoURL: https://charts.bitnami.com/bitnami
    chart: postgresql
    targetRevision: 16.7.27
    helm:
      values: |
        global:
          postgresql:
            auth:
              database: appdb
              username: app
              existingSecret: app-postgres-test
        primary:
          persistence:
            size: 10Gi
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
          podSecurityContext:
            enabled: true
        volumePermissions:
          enabled: true
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-prod
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: prod
  source:
    repoURL: ${ARGO_REPO_URL}
    path: charts/demo-app
    targetRevision: ${ARGO_TARGET_REVISION}
    helm:
      values: |
        fullnameOverride: prod
        envName: prod
        robots: |
          User-agent: *
          Allow: /
        siteTitle: "PROD"
        ingress:
          host: ${HOST_SITE}
          tlsSecret: prod-site-tls
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-test
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: test
  source:
    repoURL: ${ARGO_REPO_URL}
    path: charts/demo-app
    targetRevision: ${ARGO_TARGET_REVISION}
    helm:
      values: |
        fullnameOverride: test
        envName: test
        robots: |
          User-agent: *
          Disallow: /
        siteTitle: "TEST"
        ingress:
          host: ${HOST_TEST}
          tlsSecret: test-site-tls
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: 77.12.0
    helm:
      values: |
        alertmanager:
          config:
            global:
              resolve_timeout: 5m
${alert_block}
        prometheus:
          prometheusSpec:
            retention: ${RETENTION_METRICS}d
            storageSpec:
              volumeClaimTemplate:
                spec:
                  accessModes:
                    - ReadWriteOnce
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
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: opensearch
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: logging
  source:
    repoURL: https://opensearch-project.github.io/helm-charts
    chart: opensearch
    targetRevision: 3.2.1
    helm:
      values: |
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
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: opensearch-dashboards
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: logging
  source:
    repoURL: https://opensearch-project.github.io/helm-charts
    chart: opensearch-dashboards
    targetRevision: 3.2.2
    helm:
      values: |
        opensearchHosts: "http://opensearch-master.logging.svc.cluster.local:9200"
        service:
          type: ClusterIP
        persistence:
          enabled: true
          size: 5Gi
        ingress:
          enabled: true
          className: nginx
          annotations:
            cert-manager.io/cluster-issuer: letsencrypt-http
            nginx.ingress.kubernetes.io/ssl-redirect: "true"
            nginx.ingress.kubernetes.io/hsts: "true"
            nginx.ingress.kubernetes.io/hsts-max-age: "31536000"
          hosts:
            - host: ${HOST_LOGS}
              paths:
                - path: /
                  pathType: Prefix
          tls:
            - secretName: logs-tls
              hosts:
                - ${HOST_LOGS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: fluent-bit
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: logging
  source:
    repoURL: https://fluent.github.io/helm-charts
    chart: fluent-bit
    targetRevision: 0.53.0
    helm:
      values: |
        serviceAccount:
          create: true
        config:
          service: |
            [SERVICE]
                Daemon Off
                Flush 1
                Log_Level info
                Parsers_File /fluent-bit/etc/parsers.conf
                Parsers_File /fluent-bit/etc/conf/custom_parsers.conf
                HTTP_Server On
                HTTP_Listen 0.0.0.0
                HTTP_Port 2020
                Health_Check On
          inputs: |
            [INPUT]
                Name tail
                Path /var/log/containers/*.log
                multiline.parser docker
                Tag kube.*
                Mem_Buf_Limit 5MB
                Skip_Long_Lines On
          filters: |
            [FILTER]
                Name kubernetes
                Match kube.*
                Kube_URL https://kubernetes.default.svc:443
                Kube_Tag_Prefix kube.var.log.containers.
                Merge_Log On
                Keep_Log Off
                Labels On
                Annotations Off
          outputs: |
            [OUTPUT]
                Name  es
                Match *
                Host  opensearch-master.logging.svc.cluster.local
                Port  9200
                HTTPS Off
                Logstash_Format On
                Logstash_Prefix fluentbit
                Replace_Dots On
                Retry_Limit False
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: jaeger
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: tracing
  source:
    repoURL: https://jaegertracing.github.io/helm-charts
    chart: jaeger
    targetRevision: 3.4.1
    helm:
      values: |
        provisionDataStore:
          cassandra: false
          elasticsearch: false
        storage:
          type: memory
        ingress:
          enabled: true
          className: nginx
          annotations:
            cert-manager.io/cluster-issuer: letsencrypt-http
            nginx.ingress.kubernetes.io/ssl-redirect: "true"
            nginx.ingress.kubernetes.io/hsts: "true"
            nginx.ingress.kubernetes.io/hsts-max-age: "31536000"
          hosts:
            - ${HOST_TRACE}
          tls:
            - secretName: trace-tls
              hosts:
                - ${HOST_TRACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: network-policies
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: prod
  source:
    repoURL: ${ARGO_REPO_URL}
    path: manifests/network-policies
    targetRevision: ${ARGO_TARGET_REVISION}
    directory:
      recurse: true
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno
  source:
    repoURL: https://kyverno.github.io/kyverno
    chart: kyverno
    targetRevision: 3.5.2
    helm:
      values: |
        replicaCount: 2
        admissionController:
          replicas: 2
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno-policies
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno
  source:
    repoURL: ${ARGO_REPO_URL}
    path: manifests/kyverno-policies
    targetRevision: ${ARGO_TARGET_REVISION}
    directory:
      recurse: true
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kubernetes-dashboard
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: kubernetes-dashboard
  source:
    repoURL: https://kubernetes.github.io/dashboard
    chart: kubernetes-dashboard
    targetRevision: 7.13.0
    helm:
      values: |
        serviceAccount:
          create: true
          name: kubernetes-dashboard
        rbac:
          clusterAdminRole: true
        ingress:
          enabled: true
          className: nginx
          annotations:
            cert-manager.io/cluster-issuer: letsencrypt-http
            nginx.ingress.kubernetes.io/ssl-redirect: "true"
            nginx.ingress.kubernetes.io/hsts: "true"
            nginx.ingress.kubernetes.io/hsts-max-age: "31536000"
          hosts:
            - ${HOST_DASHBOARD}
          tls:
            - secretName: kubernetes-dashboard-tls
              hosts:
                - ${HOST_DASHBOARD}
        metricsScraper:
          enabled: true
        protocolHttp: true
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
}

alert_config() {
  case "$ALERT_MODE" in
    telegram)
      cat <<EOF
    route:
      receiver: telegram
    receivers:
      - name: telegram
        telegram_configs:
          - bot_token: "${TELEGRAM_BOT_TOKEN}"
            chat_id: "${TELEGRAM_CHAT_ID}"
EOF
      ;;
    email)
      cat <<EOF
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
EOF
      ;;
    *)
      cat <<'EOF'
    route:
      receiver: devnull
    receivers:
      - name: devnull
EOF
      ;;
  esac
}

wait_for_applications() {
  wait_rollout prod statefulset postgres-prod-postgresql
  wait_rollout test statefulset postgres-test-postgresql
  wait_rollout prod deployment prod-web
  wait_rollout prod deployment prod-api
  wait_rollout test deployment test-web
  wait_rollout test deployment test-api
  wait_rollout observability deployment kube-prometheus-stack-grafana
  wait_rollout logging statefulset opensearch-master
  wait_rollout logging deployment opensearch-dashboards
  kubectl -n logging rollout status daemonset/fluent-bit --timeout=10m || true
  wait_rollout tracing deployment jaeger-query
  wait_rollout kubernetes-dashboard deployment kubernetes-dashboard
  wait_for_kyverno_deployments
}

wait_for_kyverno_deployments() {
  local deployments
  mapfile -t deployments < <(kubectl -n kyverno get deployments -o jsonpath='{range .items[*]}{.metadata.name}{"
"}{end}' 2>/dev/null || true)
  local deploy
  for deploy in "${deployments[@]}"; do
    if [[ -n "$deploy" ]]; then
      wait_rollout kyverno deployment "$deploy"
    fi
  done
}


apply_ingress() {
  local name="$1" namespace="$2" host="$3" svc="$4" port="$5" tlsSecret="$6" extra_path="$7" extra_service="$8" extra_port="$9" annotations="${10}"
  local formatted_annotations="" extra_block=""
  if [[ -n "$annotations" ]]; then
    formatted_annotations="$(printf '%s\n' "$annotations" | sed 's/^/    /')"
  fi
  if [[ -n "$extra_path" && -n "$extra_service" && -n "$extra_port" ]]; then
    extra_block="$(cat <<EOF
          - path: ${extra_path}
            pathType: Prefix
            backend:
              service:
                name: ${extra_service}
                port:
                  number: ${extra_port}
EOF
)"
  fi
  cat <<EOI | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${name}
  namespace: ${namespace}
  annotations:
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: letsencrypt-http
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/hsts: "true"
    nginx.ingress.kubernetes.io/hsts-max-age: "31536000"
    nginx.ingress.kubernetes.io/proxy-body-size: "32m"
$(if [[ -n "$formatted_annotations" ]]; then printf '%s\n' "$formatted_annotations"; fi)
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
$(if [[ -n "$extra_block" ]]; then printf '%s\n' "$extra_block"; fi)
EOI
}

wait_rollout() {
  local ns="$1" kind="$2" name="$3"
  kubectl -n "$ns" rollout status "$kind"/"$name" --timeout=10m || true
}

wait_for_certificates() {
  local namespaces=(argocd prod test observability logging tracing kubernetes-dashboard)
  local ns cert
  for ns in "${namespaces[@]}"; do
    for cert in $(kubectl -n "$ns" get certificates.cert-manager.io -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      kubectl -n "$ns" wait certificate "$cert" --for=condition=Ready --timeout=15m || true
    done
  done
}

print_summary() {
  local ARGO_PWD POSTGRES_PASSWORD_PROD POSTGRES_PASSWORD_TEST
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
  K8s UI  : https://${HOST_DASHBOARD}

Credentials:
  Argo CD admin password: ${ARGO_PWD}
  PostgreSQL PROD DSN: postgresql://app:${POSTGRES_PASSWORD_PROD}@postgres-prod-postgresql.prod.svc.cluster.local:5432/appdb
  PostgreSQL TEST DSN: postgresql://app:${POSTGRES_PASSWORD_TEST}@postgres-test-postgresql.test.svc.cluster.local:5432/appdb
  Kubernetes dashboard token: kubectl -n kubernetes-dashboard create token kubernetes-dashboard

Health checks:
  curl -k https://${HOST_SITE}/api/health
  curl -k https://${HOST_TEST}/api/health
  kubectl get pods -A
  kubectl get ingress -A

To change domains later:
  kubectl patch ingress <name> -n <namespace> --type merge -p '{"spec":{"rules":[{"host":"new.host"}]}}' && certificates will renew automatically.
========================================
EOR
}

main "$@"
