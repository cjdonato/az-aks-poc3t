resource "random_password" "postgres_admin" {
  length           = 32
  special          = true
  override_special = "-_.~"
}

# Password for the least-privilege application role. The role itself is created
# inside the database by the db-migrate Helm hook (the server is private, so
# Terraform running in GitHub Actions can't reach it).
resource "random_password" "postgres_app" {
  length           = 32
  special          = true
  override_special = "-_.~"
}

resource "azurerm_postgresql_flexible_server" "main" {
  name                = "${var.prefix}-pg-${local.suffix}"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.main.name
  version             = var.postgres_version
  sku_name            = var.postgres_sku
  storage_mb          = var.postgres_storage_mb

  # Private access only: reachable from the VNet (AKS), not the internet.
  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false

  administrator_login    = "pgadmin"
  administrator_password = random_password.postgres_admin.result

  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = false
  }

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  tags = local.tags

  # Azure picks an availability zone when none is given; don't fight it afterwards.
  lifecycle {
    ignore_changes = [zone]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = var.postgres_database
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}
