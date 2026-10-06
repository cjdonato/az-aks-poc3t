# Three-Tier PoC on Azure Kubernetes Service

A proof-of-concept three-tier web app, built and deployed to AKS by GitHub Actions.

| Tier         | Tech                            | Runs on (Azure)                          |
| ------------ | ------------------------------- | ---------------------------------------- |
| Presentation | React (Vite), served by nginx   | AKS                                      |
| Application  | Node.js / Express REST API      | AKS                                      |
| Data         | PostgreSQL                      | Azure Database for PostgreSQL (Flexible) |

## Repository layout

```
frontend/        React app, nginx config, Dockerfile
backend/         Express API, SQL migrations, tests, Dockerfile
infra/           Terraform for Azure resources            (phase 2)
deploy/helm/     Helm chart for the app                   (phase 3)
.github/         CI/CD workflows                          (phase 4)
docker-compose.yml   Local run of all three tiers
```

## Run locally

With Docker:

```sh
docker compose up --build
# open http://localhost:8080
```

Without Docker (needs a local Postgres):

```sh
cd backend && npm install
PGHOST=localhost PGUSER=app PGPASSWORD=app PGDATABASE=app PGSSLMODE=disable npm run dev

cd frontend && npm install && npm run dev   # http://localhost:5173, proxies /api to :3000
```

## Backend API

| Method | Path              | Purpose                                         |
| ------ | ----------------- | ----------------------------------------------- |
| GET    | `/healthz`        | Liveness probe (no DB check)                    |
| GET    | `/readyz`         | Readiness probe (checks DB)                     |
| GET    | `/api/info`       | Pod hostname + app version (shows load balancing) |
| GET    | `/api/items`      | List items                                      |
| POST   | `/api/items`      | Create item `{ "name": "..." }`                 |
| DELETE | `/api/items/:id`  | Delete item                                     |

Configuration is via environment variables: `PORT`, `APP_VERSION`, and the standard
libpq variables `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `PGSSLMODE`
(use `require` for Azure Database for PostgreSQL).

Migrations in `backend/migrations/*.sql` run automatically at startup, guarded by a
Postgres advisory lock so multiple replicas can start at once safely.

```sh
cd backend && npm test
```

## Roadmap

1. ✅ App scaffold + local docker-compose
2. Terraform: resource group, ACR, AKS, PostgreSQL Flexible Server, Key Vault, GitHub OIDC
3. Helm chart: deployments, services, ingress, probes, secrets
4. GitHub Actions: CI (test/build), CD (push to ACR, `helm upgrade`), infra (plan/apply), destroy
5. End-to-end verification and teardown
