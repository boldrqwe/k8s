# Minimal Kustomize example

Этот репозиторий теперь содержит минимальный пример приложения, которое успешно рендерится командой
`kustomize build environments/production`. Базовый слой создаёт пространство имён `demo`, ConfigMap с
параметрами приложения, Deployment из образа `nginx` и Service для экспонирования порта 80. Оверлей для
окружения production увеличивает число реплик и переопределяет значения переменных окружения в ConfigMap.

## Структура

```
base/
  configmap.yaml
  deployment.yaml
  kustomization.yaml
  namespace.yaml
  service.yaml
environments/
  production/
    kustomization.yaml
argocd/
  apps/
  projects/
.github/workflows/
  validate.yaml
```

## Проверка

```bash
kustomize build environments/production
```

Полученный вывод можно применить в кластер Kubernetes:

```bash
kustomize build environments/production | kubectl apply -f -
```
