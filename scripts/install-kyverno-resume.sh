#!/usr/bin/env bash
set -euo pipefail

main() {
  ensure_root "$@"
  ensure_requirements
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

  install_kyverno_manifests
  apply_baseline_policies
  wait_for_certificates
  print_summary
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
  fi
}

ensure_requirements() {
  local bins=(kubectl curl base64)
  for bin in "${bins[@]}"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "[ERROR] Required command '$bin' not found. Install it before running." >&2
      exit 1
    fi
  done
}

install_kyverno_manifests() {
  local manifest_url="https://github.com/kyverno/kyverno/releases/latest/download/install.yaml"
  local tmp
  tmp="$(mktemp)"
  curl -fsSL "$manifest_url" -o "$tmp"
  trap 'rm -f "$tmp"' RETURN

  kubectl apply --server-side --force-conflicts -f "$tmp"

  mapfile -t deployments < <(kubectl -n kyverno get deployments -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

  if [[ ${#deployments[@]} -eq 0 ]]; then
    echo "[ERROR] No Kyverno deployments were found in the 'kyverno' namespace." >&2
    echo "        Check the manifest at $manifest_url and try again." >&2
    exit 1
  fi

  local deploy
  for deploy in "${deployments[@]}"; do
    kubectl -n kyverno rollout status "deployment/${deploy}" --timeout=10m
  done
}

apply_baseline_policies() {
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
      exclude:
        resources:
          namespaces:
            - kube-system
            - kube-public
            - kyverno
            - cert-manager
            - ingress-nginx
            - argocd
      validate:
        message: Containers must set runAsNonRoot true.
        anyPattern:
          - spec:
              securityContext:
                runAsNonRoot: true
          - spec:
              containers:
                - securityContext:
                    runAsNonRoot: true
EOCPOL
}

wait_for_certificates() {
  local namespaces=(argocd prod test observability logging tracing)
  local ns cert
  for ns in "${namespaces[@]}"; do
    for cert in $(kubectl -n "$ns" get certificates.cert-manager.io -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      kubectl -n "$ns" wait certificate "$cert" --for=condition=Ready --timeout=15m || true
    done
  done
}

print_summary() {
  local host_argo host_grafana host_logs host_trace host_site host_test
  host_argo="$(kubectl -n argocd get ingress argocd -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo 'N/A')"
  host_grafana="$(kubectl -n observability get ingress grafana -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo 'N/A')"
  host_logs="$(kubectl -n logging get ingress opensearch -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo 'N/A')"
  host_trace="$(kubectl -n tracing get ingress tracing -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo 'N/A')"
  host_site="$(kubectl -n prod get ingress prod-site -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo 'N/A')"
  host_test="$(kubectl -n test get ingress test-site -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo 'N/A')"

  local argo_pwd pg_prod pg_test
  argo_pwd="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo 'N/A')"
  pg_prod="$(kubectl -n prod get secret app-postgres-prod -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d || echo 'N/A')"
  pg_test="$(kubectl -n test get secret app-postgres-test -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d || echo 'N/A')"

  cat <<EOR
========================================
Kyverno installation complete.
Public endpoints:
  Argo CD : https://${host_argo}
  Grafana : https://${host_grafana}
  Logs    : https://${host_logs}
  Trace   : https://${host_trace}
  PROD    : https://${host_site}
  TEST    : https://${host_test}

Credentials:
  Argo CD admin password: ${argo_pwd}
  PostgreSQL PROD DSN: postgresql://app:${pg_prod}@postgres-prod-postgresql.prod.svc.cluster.local:5432/appdb
  PostgreSQL TEST DSN: postgresql://app:${pg_test}@postgres-test-postgresql.test.svc.cluster.local:5432/appdb

Health checks:
  curl -k https://${host_site}/api/health
  curl -k https://${host_test}/api/health
  kubectl get pods -A
  kubectl get ingress -A
========================================
EOR
}

main "$@"
