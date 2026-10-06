data "azurerm_client_config" "current" {}

# The resource group is created by bootstrap.sh so the CI identity can be scoped to it.
data "azurerm_resource_group" "main" {
  name = local.resource_group_name
}

# Globally unique names (ACR, Key Vault, Postgres) need a suffix.
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  resource_group_name = coalesce(var.resource_group_name, "${var.prefix}-rg")
  location            = var.location
  suffix              = random_string.suffix.result

  tags = {
    project    = var.prefix
    managed-by = "terraform"
  }
}
