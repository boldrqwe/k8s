# Production-grade Kubernetes platform

Этот репозиторий содержит полный набор декларативных манифестов Kubernetes и GitHub Actions для запуска современного веб-приложения в продакшене. Архитектура включает фронтенд, бэкенд, PostgreSQL, Kafka, OpenSearch и Grafana, а также политики безопасности, квоты ресурсов и пайплайн CI/CD.

## Структура

```
base/
  namespaces/          # пространства имён, квоты и ограничения
  apps/                # приложения (frontend, backend)
  data/                # базы данных и брокеры (Postgres, Kafka, OpenSearch)
  networking/          # общие ingress и сетевые настройки
  observability/       # Grafana и связанные секреты
  monitoring/          # ServiceMonitor для Prometheus Operator
  security/            # сетевые политики, ClusterIssuer cert-manager
  storage/             # классы хранения для stateful сервисов
environments/
  production/          # kustomization для сборки полного стека
argocd/
  apps/                # Argo CD Application манифесты
.github/workflows/     # GitHub Actions для валидации и публикации образов
```

## Подготовка к деплою

1. **Секреты и сертификаты**: замените значения в `Secret` манифестах (пароли, TLS, htpasswd) своими реальными данными. Для автоматизации рекомендуются SealedSecrets или External Secrets.
2. **Образы контейнеров**: обновите поля `image` в манифестах backend и frontend (и CronJob бэкапов) на свои регистры. Workflow `build-and-push` автоматически соберёт образы, если в каталоге существуют `frontend/Dockerfile` и `backend/Dockerfile`.
3. **Ingress и домены**: замените домены `app.example.com`, `api.example.com` и `grafana.example.com` на свои. Убедитесь, что в кластере установлен ingress-контроллер (например, nginx) и cert-manager.
4. **Объектное хранилище**: в секрете `object-storage-credentials` задайте доступ к S3-совместимому хранилищу для бэкапов PostgreSQL.
5. **Хранилище**: отредактируйте `base/storage/fast-storageclass.yaml` под вашего провайдера (сейчас пример для AWS EBS gp3). При необходимости добавьте другие `StorageClass`.
6. **Мониторинг**: ServiceMonitor ресурсы предполагают наличие Prometheus Operator. Настройте Prometheus и Alertmanager отдельно.

## Деплой локально/вручную

```bash
# проверка манифестов
kustomize build environments/production | kubeconform -strict -ignore-missing-schemas

# применение в кластере
kustomize build environments/production | kubectl apply -f -
```

После деплоя проверьте статус ключевых компонентов:

```bash
kubectl get pods -n app
kubectl get pods -n data
kubectl get pods -n streaming
kubectl get pods -n observability
```

## CI/CD с GitHub Actions

Workflow `.github/workflows/ci-cd.yaml` выполняет следующие этапы:

1. **Validate** – рендерит Kustomize, валидирует манифесты через kubeconform и yamllint.
2. **Build and push** – собирает и пушит образы фронтенда и бэкенда в GHCR (если есть Dockerfile).
3. **Bump overlay** – обновляет теги образов в `environments/production/kustomization.yaml` и создаёт Pull Request с изменениями.

Необходимые секреты:

- (Опционально) дополнительные секреты для docker login, если используется сторонний регистр.

## GitOps (Argo CD)

- Статус приложения можно проверить в веб-интерфейсе Argo CD или через CLI командой `argocd app get instructions-prod`.
- Источник правды для Argo CD описан в [argocd/apps/prod.yaml](argocd/apps/prod.yaml).
- Процесс доставки: GitHub Actions собирает и публикует образы → создаётся PR с обновлёнными тегами в `environments/production` → после мержа Argo CD автоматически синхронизирует состояние кластера.

## Дополнительные рекомендации

- Настройте резервное копирование S3-бакета и ротацию бэкапов PostgreSQL.
- Включите аудиторский лог Kubernetes и политики безопасности (OPA/Gatekeeper), если требуется.
- Для Kafka и OpenSearch рекомендуется настроить отдельные кластеры мониторинга и алерты на задержки/репликацию.
- Рассмотрите использование ArgoCD или Flux для GitOps, используя предоставленные Kustomize-манифесты в качестве источника.

## Лицензия

Этот репозиторий содержит пример инфраструктуры и может свободно адаптироваться под ваши нужды.
