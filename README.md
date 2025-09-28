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

## Подготовка окружения

Перед запуском основного скрипта [`scripts/install.sh`](scripts/install.sh) выполните установку системных зависимостей (CLI-инструменты, бинарники `kubectl`/`helm`, утилита `argocd`) при помощи помощника [`scripts/install-dependencies.sh`](scripts/install-dependencies.sh). Скрипт автоматически определит пакетный менеджер (APT/YUM/DNF/Zypper) и поставит требуемые пакеты.

```bash
# Одноразовый запуск без клонирования (замените <org>/<repo> на актуальные значения)
curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/main/scripts/install-dependencies.sh | bash

# или, находясь в корне репозитория
sudo ./scripts/install-dependencies.sh
```

### Если установка остановилась на Kyverno

Иногда при применении манифестов Kyverno через `kubectl apply` возникает ошибка вида:

```
CustomResourceDefinition.apiextensions.k8s.io "clusterpolicies.kyverno.io" is invalid: metadata.annotations: Too long
```

Чтобы продолжить установку без повторного запуска уже пройденных этапов, воспользуйтесь скриптом [`scripts/install-kyverno-resume.sh`](scripts/install-kyverno-resume.sh). Он применяет официальный манифест Kyverno в режиме *server-side apply*, дожидается развёртывания контроллеров, устанавливает базовые политики и формирует итоговое резюме по доступам.

```bash
sudo ./scripts/install-kyverno-resume.sh
```

Скрипт можно запускать повторно — он идемпотентен.

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
# Argo CD admin password:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# Вход в ArgoCD CLI (если установлен argocd):
argocd login argo.79.174.84.176.sslip.io --username admin --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)" --grpc-web

# Grafana admin password:
kubectl -n observability get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo

# PostgreSQL DSN (внутри кластера):
# PROD
export PGPASS_PROD=$(kubectl -n prod get secret app-postgres-prod -o jsonpath='{.data.postgres-password}' | base64 -d)
echo "postgresql://app:${PGPASS_PROD}@postgres-prod-postgresql.prod.svc.cluster.local:5432/appdb"
# TEST
export PGPASS_TEST=$(kubectl -n test get secret app-postgres-test -o jsonpath='{.data.postgres-password}' | base64 -d)
echo "postgresql://app:${PGPASS_TEST}@postgres-test-postgresql.test.svc.cluster.local:5432/appdb"
