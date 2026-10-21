# Three-Tier PoC on Azure Kubernetes Service

A proof-of-concept three-tier web app, built and deployed to AKS by GitHub Actions.

| Tier         | Tech                            | Runs on (Azure)                          |
| ------------ | ------------------------------- | ---------------------------------------- |
| Presentation | React (Vite), served by nginx   | AKS                                      |
| Application  | Node.js / Express REST API      | AKS                                      |
| Data         | PostgreSQL                      | Azure Database for PostgreSQL (Flexible) |

## Architecture

Serving a request (solid: traffic, dotted: images and secrets):

```mermaid
flowchart LR
  user([Browser]) -- HTTPS --> afd["Azure Front Door<br/>azurefd.net, TLS"]
  afd -- "HTTP + X-Azure-FDID" --> lb["Load balancer<br/>Front Door only"]
  subgraph vnet["VNet (private)"]
    subgraph aks["AKS, namespace poc3t"]
      fe["frontend<br/>nginx"] -- /api --> be["backend<br/>Express"]
      job["db-migrate job<br/>pre-deploy hook"]
    end
    pg[("PostgreSQL<br/>private subnet")]
  end
  lb --> fe
  be -- "SQL as app_user" --> pg
  job -- "migrations + grants as pgadmin" --> pg
  acr["Container Registry"] -. image pull .-> aks
  kv["Key Vault"] -. "passwords via CSI" .-> aks
```

Shipping a change:

```mermaid
flowchart LR
  push([git push]) --> ci["CI<br/>PR checks"]
  push --> infra["Infra<br/>terraform plan / apply"]
  push --> cd["CD<br/>build, push, helm"]
  infra -- on success --> cd
  infra -. OIDC token .-> entra["Entra ID<br/>poc3t-github-ci"]
  cd -. OIDC token .-> entra
  entra --> state[("Terraform state")]
  entra --> rg["poc3t-rg resources"]
  entra --> acr["Container Registry"]
  entra --> aks["AKS"]
```

## Repository layout

```
frontend/        React app, nginx config, Dockerfile
backend/         Express API, SQL migrations, tests, Dockerfile
infra/           Bootstrap script + Terraform for Azure (see infra/README.md)
deploy/helm/     Helm chart (frontend, backend, Key Vault secret, optional Gateway)
.github/         CI/CD workflows
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

## Observability

Logs go to one Log Analytics workspace, `poc3t-law`, and metrics to an Azure Monitor
workspace (managed Prometheus), `poc3t-amw` (see
[infra/terraform/monitoring.tf](infra/terraform/monitoring.tf)):

| What | Source | Where to look |
| ---- | ------ | ------------- |
| Node, pod and container CPU, memory, network, disk; Kubernetes object state | Managed Prometheus (`ama-metrics` pods scrape cAdvisor, kubelet, node-exporter, kube-state-metrics) | AKS > Monitoring > Dashboards with Grafana, or Insights |
| Pod status and restarts, Kubernetes events | Container Insights (AKS monitoring add-on, every 5 min) | AKS > Monitoring > Insights |
| Container stdout/stderr (nginx access logs, backend output) | Container Insights, `ContainerLogV2` table (Basic plan) | AKS > Monitoring > Logs, or live under Insights > Containers |
| Backend requests, SQL calls, exceptions, application map | Application Insights `poc3t-appi`, sent by OpenTelemetry in the backend | Application Insights > Application map / Failures / Performance / Live metrics |
| Edge requests and failed origin probes | Front Door diagnostic logs | Log Analytics, `AzureDiagnostics` |
| Slow SQL (over 500 ms) and server errors | PostgreSQL diagnostic logs | Log Analytics, `AzureDiagnostics` |
| Secret reads and changes | Key Vault audit logs | Log Analytics, `AzureDiagnostics` |
| Entra sign-ins and authorization decisions on the API server | AKS control-plane logs (`guard`; audit logs are off, ~0.7 GB/day) | Log Analytics, `AKSControlPlane` |

The backend preloads [backend/src/telemetry.js](backend/src/telemetry.js)
(`node --import`), which starts the Microsoft OpenTelemetry Distro only when
`APPLICATIONINSIGHTS_CONNECTION_STRING` is set, so local runs and tests send nothing.
Application Insights has key-based ingestion disabled: pods authenticate with the
backend's workload identity (`Monitoring Metrics Publisher` on the resource).
Kubelet probes (`/healthz`, `/readyz`) are not traced.

Example queries (workspace > Logs):

```kusto
// Slowest backend operations in the last hour
AppRequests
| where TimeGenerated > ago(1h)
| summarize count(), p95 = percentile(DurationMs, 95) by Name
| order by p95 desc

// Front Door responses by status code
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| summarize count() by httpStatusCode_s, bin(TimeGenerated, 5m)

// Slow SQL statements
AzureDiagnostics
| where Category == "PostgreSQLLogs" and Message has "duration:"
| project TimeGenerated, Message
```

Grafana dashboards: open the cluster in the Azure portal, then **Monitoring > Dashboards
with Grafana**. The prebuilt Kubernetes dashboards (Compute Resources by cluster,
namespace, pod, node; Kubelet; Networking) read from `poc3t-amw` and need no Grafana
instance. They rely on the recording rules in
[prometheus_rules.tf](infra/terraform/prometheus_rules.tf). Ad hoc PromQL: `poc3t-amw` >
Prometheus explorer.

`ContainerLogV2` is a Basic-plan table: query it on its own (`ContainerLogV2 | where
PodNamespace == "poc3t"`), not through `union *` or joins with other tables. Outside the
portal it needs the `/search` API rather than `/query`.

To keep costs predictable, the workspace has a 0.5 GB/day ingestion cap
(`log_analytics_daily_quota_gb`) and 30-day retention.

## CI/CD

| Workflow | Trigger | What it does |
| -------- | ------- | ------------ |
| `CI` | PRs touching app or chart | Backend tests, frontend build, Helm lint, image builds (no push) |
| `Infra` | PR / push to `main` touching `infra/terraform`, manual | PR: `terraform plan`, summary comment (addresses only). `main`: plan + apply |
| `CD` | push to `main` touching app or chart, after a successful `Infra` run, manual | Tests, then builds and pushes images tagged with the commit SHA to ACR, `helm upgrade --install`, smoke test through Front Door (or the public IP when it's disabled) |
| `Destroy` | manual, type `destroy` to confirm | `terraform destroy` of everything in `poc3t-rg` |

All Azure access uses GitHub OIDC with the `poc3t-github-ci` managed identity; there are
no Azure credentials stored in GitHub. Deploying jobs run in the `dev` environment, which
only the `main` branch can use. See [infra/README.md](infra/README.md) for the one-time
bootstrap.

## Roadmap

1. ✅ App scaffold + local docker-compose
2. ✅ Terraform: VNet, ACR, AKS, PostgreSQL Flexible Server (private), Key Vault, GitHub OIDC bootstrap
3. ✅ Helm chart: deployments, services, LoadBalancer (or Gateway API), probes, Key Vault secrets
4. ✅ GitHub Actions: CI (test/build), CD (push to ACR, `helm upgrade`), infra (plan/apply), destroy
5. End-to-end verification and teardown
6. Observability
   - ✅ Log Analytics, Container Insights, diagnostic settings (Front Door, PostgreSQL, Key Vault, AKS)
   - ✅ Application Insights via OpenTelemetry in the backend
   - ✅ Managed Prometheus + Grafana dashboards (Azure portal)
   - Alert rules + email action group
