# Consumed by the CD workflow (terraform output -json) to fill in Helm values.

output "resource_group_name" {
  value = data.azurerm_resource_group.main.name
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "acr_name" {
  value = azurerm_container_registry.main.name
  # Hidden from public workflow logs (cd.yml still reads it via output -json).
  sensitive = true
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
  # Hidden from public workflow logs (cd.yml still reads it via output -json).
  sensitive = true
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
  # Hidden from public workflow logs (cd.yml still reads it via output -json).
  sensitive = true
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "postgres_host" {
  value = azurerm_postgresql_flexible_server.main.fqdn
  # Hidden from public workflow logs (cd.yml still reads it via output -json).
  sensitive = true
}

output "postgres_admin_user" {
  value = azurerm_postgresql_flexible_server.main.administrator_login
}

output "postgres_app_user" {
  value = var.postgres_app_user
}

output "postgres_database" {
  value = azurerm_postgresql_flexible_server_database.app.name
}

output "postgres_admin_password_secret_name" {
  value = azurerm_key_vault_secret.postgres_admin_password.name
}

output "postgres_app_password_secret_name" {
  value = azurerm_key_vault_secret.postgres_app_password.name
}

output "backend_identity_client_id" {
  value = azurerm_user_assigned_identity.workload["backend"].client_id
  # Hidden from public workflow logs (cd.yml still reads it via output -json).
  sensitive = true
}

output "migrate_identity_client_id" {
  value = azurerm_user_assigned_identity.workload["migrate"].client_id
  # Hidden from public workflow logs (cd.yml still reads it via output -json).
  sensitive = true
}

output "app_namespace" {
  value = var.app_namespace
}

output "backend_service_account" {
  value = var.backend_service_account
}

output "migrate_service_account" {
  value = var.migrate_service_account
}

output "gateway_api_enabled" {
  value = var.enable_gateway_api
}

# Random suffix shared by the globally unique resource names. Workflows mask it
# so those names stay out of public logs.
output "name_suffix" {
  value     = local.suffix
  sensitive = true
}
