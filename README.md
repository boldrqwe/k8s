# Argo CD Applications

This repository defines the Argo CD applications that deliver the backend service and the PostgreSQL databases for the `prod` and `test` environments.

## Application layout

| Application | Path | Destination namespace |
|-------------|------|-----------------------|
| `backend-prod` | `apps/backend/overlays/prod` | `prod` |
| `backend-test` | `apps/backend/overlays/test` | `test` |
| `db-prod` | `apps/db/overlays/prod` | `db` |
| `db-test` | `apps/db/overlays/test` | `db-test` |

Argo CD manifests that register these applications live under `clusters/prod/apps.yaml` and `clusters/test/apps.yaml`. The shared Argo CD project is defined in `clusters/projects/app-project.yaml` and allows access to the Git repository as well as the Bitnami OCI registry.

## Backend configuration

Backend configuration for each environment is stored alongside the overlays:

- ConfigMaps (`backend-config.yaml`) provide `BACKEND_URL`, `DB_HOST`, `DB_PORT`, `DB_NAME`, and `DB_USER` values.
- Secrets (`db-auth-secret.yaml`) expose the database password that the backend consumes. The current values are placeholders (`changeme-*`). Replace them before syncing to production.

Readiness and liveness probes are defined in `apps/backend/base/deployment.yaml` and expect the container to respond on `/` using port `80`.

## PostgreSQL configuration

The PostgreSQL instances are deployed from the Bitnami OCI chart (`oci://registry-1.docker.io/bitnamicharts`) pinned to version `16.7.27`. Values are embedded in the corresponding `app-postgres.yaml` manifests. Secrets named `db-auth` in each overlay provide the credentials consumed both by the chart and the backend.

## Syncing changes

1. Commit updates to this repository and push them to the branch tracked by Argo CD.
2. In the Argo CD UI, select the desired application (for example `backend-prod`) and press **Sync**.
3. Alternatively, use the CLI:

   ```bash
   argocd app sync backend-prod
   argocd app sync db-prod
   ```

   Add `-h` to see more options, such as syncing `backend-test` or `db-test`.

Remember to update the placeholder passwords in the secrets before performing a production sync.
