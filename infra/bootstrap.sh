#!/usr/bin/env bash
# One-time setup, run locally by a subscription Owner (az login + gh auth login).
#
#   ./infra/bootstrap.sh <github-owner>/<repo>
#
# Creates what Terraform itself needs before it can run in GitHub Actions:
#   - resource provider registrations
#   - <prefix>-tfstate-rg: storage account for Terraform state, CI managed identity
#   - <prefix>-rg: empty resource group that Terraform fills
#   - OIDC federated credentials so GitHub Actions can log in without secrets
#   - role assignments for the CI identity and for you
#   - GitHub Actions secrets, the "dev" environment (main only) and repo hardening
#
# Safe to re-run.
set -euo pipefail

GITHUB_REPO="${1:?usage: $0 <github-owner>/<repo>}"
PREFIX="${PREFIX:-poc3t}"
LOCATION="${LOCATION:-swedencentral}"
GH_ENVIRONMENT="${GH_ENVIRONMENT:-dev}"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
ME_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv)"

APP_RG="${PREFIX}-rg"
STATE_RG="${PREFIX}-tfstate-rg"
# Storage account names are global; derive a stable suffix from the subscription.
STATE_SA="${PREFIX}tfstate$(printf %s "$SUBSCRIPTION_ID" | shasum | cut -c1-6)"
STATE_CONTAINER="tfstate"
STATE_KEY="${PREFIX}.tfstate"
CI_IDENTITY="${PREFIX}-github-ci"

log() { printf '\n==> %s\n' "$*"; }

# Create a role assignment unless it already exists.
assign_role() { # <principal-object-id> <principal-type> <role> <scope>
  local existing
  existing="$(az role assignment list --assignee "$1" --role "$3" --scope "$4" --query '[0].id' -o tsv)"
  if [[ -z "$existing" ]]; then
    az role assignment create --assignee-object-id "$1" --assignee-principal-type "$2" \
      --role "$3" --scope "$4" -o none
    echo "    + $3 -> ${4##*/}"
  else
    echo "    = $3 -> ${4##*/} (exists)"
  fi
}

log "Subscription $SUBSCRIPTION_ID, region $LOCATION, repo $GITHUB_REPO"

# Repos created after 2026-07-15 use immutable OIDC subjects:
#   repo:<owner>@<owner-id>/<repo>@<repo-id>:...
log "Looking up GitHub repository IDs"
read -r GH_OWNER GH_OWNER_ID GH_REPO_NAME GH_REPO_ID < <(
  gh api "repos/$GITHUB_REPO" --jq '"\(.owner.login) \(.owner.id) \(.name) \(.id)"'
)
[[ -n "${GH_REPO_ID:-}" ]] || { echo "Can't read $GITHUB_REPO with gh; does it exist and is gh logged in?" >&2; exit 1; }
OIDC_REPO="repo:${GH_OWNER}@${GH_OWNER_ID}/${GH_REPO_NAME}@${GH_REPO_ID}"
echo "    subject prefix: $OIDC_REPO"

log "Registering resource providers (can take a few minutes the first time)"
for ns in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.DBforPostgreSQL \
          Microsoft.KeyVault Microsoft.ManagedIdentity Microsoft.Network Microsoft.Storage \
          Microsoft.Compute Microsoft.OperationalInsights Microsoft.Cdn; do
  az provider register --namespace "$ns" --wait -o none
  echo "    $ns"
done

log "Resource groups"
az group create -n "$STATE_RG" -l "$LOCATION" --tags project="$PREFIX" -o none
az group create -n "$APP_RG" -l "$LOCATION" --tags project="$PREFIX" -o none
APP_RG_ID="$(az group show -n "$APP_RG" --query id -o tsv)"

log "Terraform state storage: $STATE_SA"
if ! az storage account show -n "$STATE_SA" -g "$STATE_RG" -o none 2>/dev/null; then
  az storage account create -n "$STATE_SA" -g "$STATE_RG" -l "$LOCATION" \
    --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
    --allow-blob-public-access false --allow-shared-key-access false -o none
fi
az storage account blob-service-properties update -n "$STATE_SA" -g "$STATE_RG" \
  --enable-versioning true --enable-delete-retention true --delete-retention-days 7 -o none
STATE_SA_ID="$(az storage account show -n "$STATE_SA" -g "$STATE_RG" --query id -o tsv)"

log "CI managed identity: $CI_IDENTITY"
az identity create -n "$CI_IDENTITY" -g "$STATE_RG" -l "$LOCATION" -o none
CI_CLIENT_ID="$(az identity show -n "$CI_IDENTITY" -g "$STATE_RG" --query clientId -o tsv)"
CI_PRINCIPAL_ID="$(az identity show -n "$CI_IDENTITY" -g "$STATE_RG" --query principalId -o tsv)"

log "Federated credentials (GitHub OIDC)"
create_fic() { # <name> <subject>
  az identity federated-credential create -n "$1" --identity-name "$CI_IDENTITY" -g "$STATE_RG" \
    --issuer "https://token.actions.githubusercontent.com" --subject "$2" \
    --audiences "api://AzureADTokenExchange" -o none
  echo "    $2"
}
create_fic "github-main"         "${OIDC_REPO}:ref:refs/heads/main"
create_fic "github-pull-request" "${OIDC_REPO}:pull_request"
create_fic "github-env-${GH_ENVIRONMENT}" "${OIDC_REPO}:environment:${GH_ENVIRONMENT}"

log "Role assignments: CI identity"
# Owner (not Contributor) because Terraform creates role assignments (AcrPull, etc.).
assign_role "$CI_PRINCIPAL_ID" ServicePrincipal "Owner"                                       "$APP_RG_ID"
assign_role "$CI_PRINCIPAL_ID" ServicePrincipal "Key Vault Secrets Officer"                   "$APP_RG_ID"
assign_role "$CI_PRINCIPAL_ID" ServicePrincipal "Azure Kubernetes Service RBAC Cluster Admin" "$APP_RG_ID"
assign_role "$CI_PRINCIPAL_ID" ServicePrincipal "Storage Blob Data Contributor"               "$STATE_SA_ID"

log "Role assignments: you (so you can run Terraform/kubectl locally)"
assign_role "$ME_OBJECT_ID" User "Key Vault Secrets Officer"                   "$APP_RG_ID"
assign_role "$ME_OBJECT_ID" User "Azure Kubernetes Service RBAC Cluster Admin" "$APP_RG_ID"
assign_role "$ME_OBJECT_ID" User "Storage Blob Data Contributor"               "$STATE_SA_ID"

log "State container (waiting for role assignment to propagate)"
for attempt in $(seq 1 20); do
  if az storage container create -n "$STATE_CONTAINER" --account-name "$STATE_SA" \
       --auth-mode login -o none 2>/dev/null; then
    echo "    $STATE_CONTAINER ready"
    break
  fi
  [[ $attempt -eq 20 ]] && { echo "Could not create container; re-run in a few minutes." >&2; exit 1; }
  sleep 15
done

log "GitHub repository hardening (the repo is public)"
# Workflow GITHUB_TOKEN is read-only unless a workflow asks for more.
gh api -X PUT "repos/$GITHUB_REPO/actions/permissions/workflow" --silent \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
echo "    default workflow token: read-only"
# Workflows from forks wait for a maintainer's approval before running.
gh api -X PUT "repos/$GITHUB_REPO/actions/permissions/fork-pr-contributor-approval" --silent \
  -f approval_policy=all_external_contributors \
  && echo "    fork PR workflows: need approval" \
  || echo "    WARN: couldn't set fork PR approval policy; set it under Settings > Actions" >&2

log "GitHub environment: $GH_ENVIRONMENT (deployable from main only)"
gh api -X PUT "repos/$GITHUB_REPO/environments/$GH_ENVIRONMENT" --silent --input - <<'JSON'
{ "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true } }
JSON
if ! gh api "repos/$GITHUB_REPO/environments/$GH_ENVIRONMENT/deployment-branch-policies" \
     --jq '.branch_policies[].name' | grep -qx main; then
  gh api -X POST "repos/$GITHUB_REPO/environments/$GH_ENVIRONMENT/deployment-branch-policies" \
    --silent -f name=main -f type=branch
fi

log "GitHub Actions secrets"
# These IDs aren't credentials (auth is OIDC), but secrets are masked in the public
# workflow logs, which keeps subscription/tenant details out of them.
set_secret() { gh secret set "$1" --body "$2" -R "$GITHUB_REPO"; echo "    $1"; }
set_secret AZURE_CLIENT_ID         "$CI_CLIENT_ID"
set_secret AZURE_TENANT_ID         "$TENANT_ID"
set_secret AZURE_SUBSCRIPTION_ID   "$SUBSCRIPTION_ID"
set_secret TFSTATE_RESOURCE_GROUP  "$STATE_RG"
set_secret TFSTATE_STORAGE_ACCOUNT "$STATE_SA"
set_secret TFSTATE_CONTAINER       "$STATE_CONTAINER"
set_secret TFSTATE_KEY             "$STATE_KEY"

log "Done. To run Terraform locally:"
cat <<EOF
    cd infra/terraform
    terraform init \\
      -backend-config="resource_group_name=$STATE_RG" \\
      -backend-config="storage_account_name=$STATE_SA" \\
      -backend-config="container_name=$STATE_CONTAINER" \\
      -backend-config="key=$STATE_KEY"
    terraform plan
EOF
