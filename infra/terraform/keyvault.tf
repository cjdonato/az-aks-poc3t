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
# on the resource group from bootstrap.sh, so it can write this secret.
resource "azurerm_key_vault_secret" "postgres_password" {
  name         = "postgres-password"
  key_vault_id = azurerm_key_vault.main.id
  value        = random_password.postgres.result
  content_type = "password"
}

# --- Backend workload identity --------------------------------------------------
# The backend pod's service account is federated with this managed identity, which
# can read secrets from the vault through the Secrets Store CSI driver.

resource "azurerm_user_assigned_identity" "backend" {
  name                = "${var.prefix}-backend-id"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "backend" {
  name                      = "aks-${var.app_namespace}-${var.backend_service_account}"
  user_assigned_identity_id = azurerm_user_assigned_identity.backend.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.app_namespace}:${var.backend_service_account}"
}

resource "azurerm_role_assignment" "backend_kv_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.backend.principal_id
  principal_type       = "ServicePrincipal"
}
