resource "azurerm_key_vault" "main" {
  name                       = "${var.prefix}-kv-${local.suffix}"
  location                   = local.location
  resource_group_name        = data.azurerm_resource_group.main.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  tags                       = local.tags
}

# Whoever runs Terraform (CI identity or you) gets "Key Vault Secrets Officer"
# on the resource group from bootstrap.sh, so it can write these secrets.

# Server admin password: only the db-migrate job can read it.
resource "azurerm_key_vault_secret" "postgres_admin_password" {
  name         = "postgres-admin-password"
  key_vault_id = azurerm_key_vault.main.id
  value        = random_password.postgres_admin.result
  content_type = "password"
}

# Application user password: read by the backend (to connect) and by the
# db-migrate job (to create/update the role with this password).
resource "azurerm_key_vault_secret" "postgres_app_password" {
  name         = "postgres-app-password"
  key_vault_id = azurerm_key_vault.main.id
  value        = random_password.postgres_app.result
  content_type = "password"
}

# --- Workload identities ----------------------------------------------------------
# Each Kubernetes service account is federated with its own managed identity, and
# each identity can read only the secrets it needs (role scoped to the secret).

locals {
  workload_identities = {
    backend = {
      service_account = var.backend_service_account
      secrets = {
        app = azurerm_key_vault_secret.postgres_app_password.resource_versionless_id
      }
    }
    migrate = {
      service_account = var.migrate_service_account
      secrets = {
        admin = azurerm_key_vault_secret.postgres_admin_password.resource_versionless_id
        app   = azurerm_key_vault_secret.postgres_app_password.resource_versionless_id
      }
    }
  }

  # Flatten to one entry per (identity, secret) pair for the role assignments.
  workload_secret_access = merge([
    for name, wi in local.workload_identities : {
      for secret, id in wi.secrets : "${name}-${secret}" => { identity = name, scope = id }
    }
  ]...)
}

resource "azurerm_user_assigned_identity" "workload" {
  for_each = local.workload_identities

  name                = "${var.prefix}-${each.key}-id"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "workload" {
  for_each = local.workload_identities

  name                      = "aks-${var.app_namespace}-${each.value.service_account}"
  user_assigned_identity_id = azurerm_user_assigned_identity.workload[each.key].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.app_namespace}:${each.value.service_account}"
}

resource "azurerm_role_assignment" "workload_secret_access" {
  for_each = local.workload_secret_access

  scope                = each.value.scope
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.workload[each.value.identity].principal_id
  principal_type       = "ServicePrincipal"
}
