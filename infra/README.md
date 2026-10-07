# Infrastructure

```
GitHub Actions ──OIDC──► poc3t-github-ci (managed identity)
                              │ Owner on poc3t-rg, blob access to state
                              ▼
poc3t-tfstate-rg                 poc3t-rg (Terraform)
 ├─ poc3ttfstate<hash>            ├─ poc3t-vnet
 │   └─ tfstate/poc3t.tfstate     │   ├─ snet-aks       10.10.0.0/22
 └─ poc3t-github-ci               │   └─ snet-postgres  10.10.8.0/24 (delegated)
                                  ├─ poc3t-aks          1 × Standard_D2als_v6, CNI overlay,
                                  │                     Entra ID + Azure RBAC, workload identity,
                                  │                     Key Vault CSI driver
                                  ├─ poc3tacr<sfx>      Basic, AcrPull for the kubelet identity
                                  ├─ poc3t-pg-<sfx>     PostgreSQL 17, B1ms, private access only
                                  ├─ poc3t-kv-<sfx>     RBAC mode: postgres-admin-password,
                                  │                     postgres-app-password
                                  ├─ poc3t-backend-id   SA poc3t/backend; reads app password only
                                  └─ poc3t-migrate-id   SA poc3t/db-migrate; reads both passwords

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
| AKS node            | 1 × Standard_D2als_v6, 32 GB OS disk | ~$65/month            |
| Load balancer + IP  | Standard                       | ~$20/month                  |
| PostgreSQL          | B_Standard_B1ms, 32 GB         | ~$17/month                  |
| Container registry  | Basic                          | ~$5/month                   |
| Key Vault, VNet, DNS | Standard                      | < $1/month                  |

Destroying the stack between demos stops almost all of it; the bootstrap resources
(state storage + identity) cost cents.

Useful variables (`terraform.tfvars` or `-var`): `node_vm_size`, `node_count`,
`enable_gateway_api` (needs bigger or more nodes), `postgres_sku`.
