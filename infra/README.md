# Infrastructure

```
GitHub Actions ──OIDC──► poc3t-github-ci (managed identity)
                              │ Owner on poc3t-rg, blob access to state
                              ▼
poc3t-tfstate-rg                 poc3t-rg (Terraform)
 ├─ poc3ttfstate<hash>            ├─ poc3t-vnet
 │   └─ tfstate/poc3t.tfstate     │   ├─ snet-aks       10.10.0.0/22
 └─ poc3t-github-ci               │   └─ snet-postgres  10.10.8.0/24 (delegated)
                                  ├─ poc3t-aks          2 × Standard_D2als_v6, CNI overlay,
                                  │                     Entra ID + Azure RBAC, workload identity,
                                  │                     Key Vault CSI driver
                                  ├─ poc3tacr<sfx>      Basic, AcrPull for the kubelet identity
                                  ├─ poc3t-pg-<sfx>     PostgreSQL 17, B1ms, private access only
                                  ├─ poc3t-kv-<sfx>     RBAC mode: postgres-admin-password,
                                  │                     postgres-app-password
                                  ├─ poc3t-backend-id   SA poc3t/backend; reads app password only
                                  ├─ poc3t-migrate-id   SA poc3t/db-migrate; reads both passwords
                                  ├─ poc3t-afd          Front Door Standard: https://<endpoint>.azurefd.net
                                  │                     -> frontend LB (<label>.<region>.cloudapp.azure.com)
                                  ├─ poc3t-law          Log Analytics: Container Insights + diagnostic
                                  │                     logs (AFD, Postgres, Key Vault, AKS), 0.5 GB/day cap
                                  ├─ MSCI-poc3t-aks     Container Insights data collection rule
                                  ├─ poc3t-amw          Azure Monitor workspace (managed Prometheus),
                                  │                     + MSProm-* endpoint/rule, recording rule groups
                                  └─ poc3t-appi         Application Insights (in poc3t-law), Entra auth
                                                        only; poc3t-backend-id may publish

Database access: the backend connects as `app_user` (SELECT/INSERT/UPDATE/DELETE only).
The `db-migrate` Helm hook runs before each deploy as `pgadmin`: it applies migrations and
creates the role or resets its password from Key Vault. The server is private, so this
runs inside the cluster rather than from GitHub Actions.
```

## One-time bootstrap

Requires `az login` as a subscription Owner, `gh auth login`, and an existing GitHub repo.

```sh
./infra/bootstrap.sh <owner>/<repo>
```

It's safe to re-run, for example when a new feature needs another resource provider
(monitoring added `Microsoft.Insights`, `Microsoft.AlertsManagement`,
`Microsoft.OperationsManagement` and `Microsoft.Monitor`). The CI identity can't register
providers itself.

This creates the state storage, the CI identity with OIDC federated credentials
(`main` branch, pull requests, `dev` environment), role assignments for CI and for you,
sets the Actions secrets the workflows read (`AZURE_*`, `TFSTATE_*`), and hardens the
public repo: read-only default workflow token, approval for fork PR workflows, and the
`dev` environment restricted to the `main` branch.

## Running Terraform locally

Normally Terraform runs from GitHub Actions. To run it yourself (Terraform ≥ 1.9):

```sh
cd infra/terraform
terraform init \
  -backend-config="resource_group_name=poc3t-tfstate-rg" \
  -backend-config="storage_account_name=<printed by bootstrap.sh>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=poc3t.tfstate"
terraform plan
```

## Sizing and cost

Region is **Sweden Central**: in France Central this subscription is blocked from every
small VM size (`NotAvailableForSubscription`). Defaults are the smallest sizes that work:

| Resource            | Default                        | Approx. cost (running 24/7) |
| ------------------- | ------------------------------ | --------------------------- |
| AKS control plane   | Free tier                      | $0                          |
| AKS nodes           | 2 × Standard_D2als_v6, 32 GB OS disk | ~$130/month           |
| Load balancer + IP  | Standard                       | ~$20/month                  |
| Front Door          | Standard (`enable_front_door`) | ~$35/month + traffic        |
| PostgreSQL          | B_Standard_B1ms, 32 GB         | ~$17/month                  |
| Container registry  | Basic                          | ~$5/month                   |
| Key Vault, VNet, DNS | Standard                      | < $1/month                  |
| Log Analytics + App Insights | Pay per GB ingested, 0.5 GB/day cap | ~$0–5/month at PoC traffic; at most ~$30/month if the cap is hit daily |
| Managed Prometheus  | Pay per metric sample ingested and queried | a few $/month for two nodes |
| Grafana dashboards  | Azure portal (Dashboards with Grafana) | $0                          |

Destroying the stack between demos stops almost all of it; the bootstrap resources
(state storage + identity) cost cents.

Useful variables (`terraform.tfvars` or `-var`): `node_vm_size`, `node_count`,
`enable_gateway_api` (needs bigger or more nodes), `enable_front_door`, `postgres_sku`,
`log_analytics_daily_quota_gb`, `postgres_slow_query_ms`.

Monitoring costs are mostly log ingestion. The first 5 GB per month is free per billing
account, container logs go to a Basic-plan table (a fraction of the Analytics price), and
Container Insights only collects logs, events and pod inventory every 5 minutes;
CPU/memory come from managed Prometheus, which is priced per sample rather than per GB.
Once the daily cap is reached, the workspace drops new data until midnight UTC.

The two monitoring agents need room: `ama-logs` (Container Insights) takes roughly
0.2 vCPU and 0.5 GiB, `ama-metrics` (Prometheus) roughly 0.25 vCPU and 0.8 GiB. With the
system pods that doesn't fit next to the app on one D2als_v6, hence two nodes.

## HTTPS via Azure Front Door

With `enable_front_door = true` (default) the app is served at
`https://<endpoint>.z01.azurefd.net` with a Microsoft-managed certificate; no custom domain
needed. HTTP is redirected to HTTPS. TLS ends at Front Door, which talks HTTP to the
frontend LoadBalancer through its Azure DNS label. The origin is locked down two ways:
the Service only admits the `AzureFrontDoor.Backend` service tag (NSG rule), and nginx
rejects requests without this profile's `X-Azure-FDID` header. A new endpoint can take
10–20 minutes to start serving; the CD smoke test waits for it.

## Cleanup

Removing everything takes three steps, in this order. Step 2 deletes the Terraform state,
so run it only after step 1 has finished.

### 1. Destroy the environment

Run the **Destroy** workflow from the Actions tab and type `destroy` to confirm (or run
`terraform destroy` locally). This removes everything Terraform created in `poc3t-rg`,
including AKS and its node resource group `poc3t-aks-nodes-rg`, PostgreSQL, ACR, Key Vault
and Front Door. Costs stop here; what remains below costs cents per month.

### 2. Remove the bootstrap resources

Run these as the subscription Owner who ran `bootstrap.sh` (works in bash and zsh):

```sh
SUB_ID="$(az account show --query id -o tsv)"
APP_RG_ID="/subscriptions/$SUB_ID/resourceGroups/poc3t-rg"
STATE_SA_ID="$(az storage account list -g poc3t-tfstate-rg --query '[0].id' -o tsv)"

# Role assignments bootstrap.sh created for the CI identity and for you. The filter keeps
# only assignments made exactly at these two scopes, never inherited subscription ones.
for scope in "$APP_RG_ID" "$STATE_SA_ID"; do
  az role assignment list --scope "$scope" --query "[?scope=='$scope'].id" -o tsv |
    while read -r id; do az role assignment delete --ids "$id"; done
done

# The empty app resource group, then the state storage account and the CI managed
# identity (its GitHub OIDC federated credentials are deleted with it).
az group delete -n poc3t-rg --yes
az group delete -n poc3t-tfstate-rg --yes
```

Deleting the role assignments first matters. If the identity goes first, its assignments
stay behind as orphaned "Identity not found" entries.

### 3. Remove the GitHub configuration

```sh
REPO=<owner>/<repo>
for s in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID \
         TFSTATE_RESOURCE_GROUP TFSTATE_STORAGE_ACCOUNT TFSTATE_CONTAINER TFSTATE_KEY; do
  gh secret delete "$s" -R "$REPO"
done
gh api -X DELETE "repos/$REPO/environments/dev"
```

Or delete the repository (`gh repo delete <owner>/<repo>`, which needs the `delete_repo`
scope: `gh auth refresh -s delete_repo`). The Actions settings `bootstrap.sh` changed (read-only
workflow token, fork approval) are harmless to keep.

### Optional leftovers (no cost)

- **Soft-deleted Key Vault**: kept for 7 days, then purged automatically. To purge now:
  `az keyvault list-deleted --query "[?starts_with(name, 'poc3t-kv-')].name" -o tsv`, then
  `az keyvault purge -n <name>`.
- **Network Watcher**: Azure creates `NetworkWatcher_swedencentral` in `NetworkWatcherRG`
  when the first VNet appears in the region. Other projects may use the same resource group,
  so only disable this region's watcher:
  `az network watcher configure -g NetworkWatcherRG -l swedencentral --enabled false`.
- **Application Insights smart detection**: creating Application Insights can add an
  "Application Insights Smart Detection" action group to `poc3t-rg` outside Terraform.
  It's deleted with the resource group in step 2.
- **Resource provider registrations** (`Microsoft.ContainerService`, `Microsoft.Cdn`, ...):
  free, and other workloads may rely on them; leave them registered.
- **Local files**: `rm -rf infra/terraform/.terraform`.

### Check that nothing is left

```sh
# contains(), not starts_with(): the Prometheus workspace's managed resource group is
# named MA_poc3t-amw_<region>_managed (deleted together with the workspace).
az group list --query "[?contains(name, 'poc3t')].name" -o tsv        # expect no output
az role assignment list --all --query "[?contains(scope, 'poc3t')]" -o table
```

To start again later, run `./infra/bootstrap.sh <owner>/<repo>` and then the Infra workflow.
