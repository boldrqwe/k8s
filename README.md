# Minimal Kubernetes GitOps stack

Этот репозиторий приведён к базовому набору манифестов, достаточному для того, чтобы Argo CD успешно синхронизировал кластер и показывал зелёный статус. Все ресурсы полностью декларативные и готовы к применению в любом кластере Kubernetes.

## Структура

```
base/
  kustomization.yaml   # основной набор ресурсов
  namespaces/          # пространство имён приложения
  app/                 # тестовое приложение (ConfigMap, Deployment, Service)
environments/
  production/          # оверлей, переопределяющий конфигурацию ConfigMap
argocd/
  apps/prod.yaml       # единственное Argo CD приложение
```

## Что разворачивается

* Namespace `app` с минимальными метаданными.
* ConfigMap `demo-config` с приветственным сообщением.
* Deployment `demo` на основе образа `ghcr.io/stefanprodan/podinfo:6.6.2`.
* Service `demo`, пробрасывающий порт 80 на HTTP-порт пода.

Оверлей `environments/production` использует kustomize, чтобы обновить значение в ConfigMap, сохранив при этом простой состав ресурсов.

## Проверка перед синхронизацией Argo CD

```bash
# Рендер манифестов
kustomize build environments/production

# Валидация схем (опционально)
kustomize build environments/production | kubeconform -strict -ignore-missing-schemas
```

Полученные YAML-файлы можно применять напрямую:

```bash
kustomize build environments/production | kubectl apply -f -
```

После применения убедитесь, что все ресурсы созданы и находятся в состоянии `Running` / `Ready`:

```bash
kubectl get all -n app
```

## Настройка Argo CD

* `argocd/apps/prod.yaml` описывает единственное приложение `instructions-prod`, направленное на директорию `environments/production` данного репозитория.
* Политика синхронизации включает автоматическое выравнивание (`selfHeal`) и очистку (`prune`), а также автоматическое создание namespace `app`.

После добавления репозитория в Argo CD достаточно синхронизировать приложение — все ресурсы будут успешно применены, и статус станет зелёным.
