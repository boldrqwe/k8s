# K3s Full-Stack — быстрые ссылки, прод/тест окружения и единые метрики

Стенд поднимает **k3s**, **ingress-nginx**, **cert-manager**, **Argo CD**, **PostgreSQL (prod/test)**, **kube-prometheus-stack (Prometheus/Alertmanager/Grafana)**, **OpenSearch + Dashboards** (логи через Fluent Bit), **Jaeger** (трейсы), **Velero** (бэкапы), **Kyverno**, а также демо-сайты **PROD/TEST**.  
Метрики **для двух окружений** собираются **одним Prometheus+Grafana** без дублирования.

> Публичный IP: **79.174.84.176** (адреса вида `*.sslip.io` доступны из Интернета по HTTPS; сертификаты выпускает cert-manager/Let’s Encrypt).

---

## 1) Быстрые ссылки (открываются с любого компьютера)

| Сервис | URL | Namespace | Примечание |
|---|---|---|---|
| **Argo CD** | https://argo.79.174.84.176.sslip.io | `argocd` | Первый вход — см. ниже |
| **Grafana** | https://grafana.79.174.84.176.sslip.io | `observability` | Одна Grafana для prod+test |
| **Логи (OpenSearch Dashboards)** | https://logs.79.174.84.176.sslip.io | `logging` | Индексы: `fluentbit*` |
| **Трейсы (Jaeger UI)** | https://trace.79.174.84.176.sslip.io | `tracing` | In-memory хранилище |
| **PROD сайт** (web + `/api`) | https://site.79.174.84.176.sslip.io | `prod` | Демо фронт/апи |
| **TEST сайт** (web + `/api`) | https://test.79.174.84.176.sslip.io | `test` | Демо фронт/апи |
| **Backend API (PROD)** | `https://site.79.174.84.176.sslip.io/api` | `prod` | Health: `/api/health` |
| **Backend API (TEST)** | `https://test.79.174.84.176.sslip.io/api` | `test` | Health: `/api/health` |
| **Kafka UI** *(если установлен)* | https://kafka.79.174.84.176.sslip.io | `kafka` | Обзор топиков/консьюмеров |
| **Redis UI** *(если установлен)* | https://redis.79.174.84.176.sslip.io | `redis` | Управление ключами |

> При необходимости добавьте также **pgAdmin**: `https://pgadmin.79.174.84.176.sslip.io` (ns `db-tools`).

---

## 2) Окружения и состав

- **prod** — ваш **backend**, **frontend**, **PostgreSQL** (`postgres-prod`).
- **test** — ваш **backend**, **frontend**, **PostgreSQL** (`postgres-test`).
- **observability** — **Prometheus/Alertmanager/Grafana** (общие для prod+test).
- **logging** — **OpenSearch + Dashboards**, **Fluent Bit** (логи контейнеров).
- **tracing** — **Jaeger** (трейсы).
- **infra** — `ingress-nginx`, `cert-manager`, `argocd`, `backups` (Velero), `kyverno`.
- *(опционально)* **kafka**, **redis** — при установке в соответствующие неймспейсы.

---

## 3) Доступ и DSN

```bash
bash <<'EOF'
# Inputs
ARGO_HOST="argo.79.174.84.176.sslip.io"

# Grab secrets (silently); fall back to N/A if missing
ARGO_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
[ -n "$ARGO_PWD" ] || ARGO_PWD="N/A"

GRAF_PWD=$(kubectl -n observability get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)
[ -n "$GRAF_PWD" ] || GRAF_PWD="N/A"

PGPASS_PROD=$(kubectl -n prod get secret app-postgres-prod -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d 2>/dev/null || true)
[ -n "$PGPASS_PROD" ] || PGPASS_PROD="N/A"

PGPASS_TEST=$(kubectl -n test get secret app-postgres-test -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d 2>/dev/null || true)
[ -n "$PGPASS_TEST" ] || PGPASS_TEST="N/A"

# Print creds and DSNs
echo "Argo CD admin password: $ARGO_PWD"
echo "Grafana admin password: $GRAF_PWD"
echo "PostgreSQL PROD DSN: postgresql://app:${PGPASS_PROD}@postgres-prod-postgresql.prod.svc.cluster.local:5432/appdb"
echo "PostgreSQL TEST DSN: postgresql://app:${PGPASS_TEST}@postgres-test-postgresql.test.svc.cluster.local:5432/appdb"

# Try ArgoCD CLI login if possible
if command -v argocd >/dev/null 2>&1 && [ "$ARGO_PWD" != "N/A" ]; then
  if argocd login "$ARGO_HOST" --username admin --password "$ARGO_PWD" --grpc-web >/dev/null 2>&1; then
    echo "ArgoCD CLI login: OK ($ARGO_HOST)"
  else
    echo "ArgoCD CLI login: FAILED ($ARGO_HOST)"
  fi
else
  echo "ArgoCD CLI login: skipped (argocd CLI not found or password N/A)"
fi
EOF
