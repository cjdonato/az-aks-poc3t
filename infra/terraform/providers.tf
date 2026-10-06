provider "azurerm" {
  # Authentication comes from the environment: `az login` locally, or
  # ARM_USE_OIDC/ARM_CLIENT_ID/ARM_TENANT_ID/ARM_SUBSCRIPTION_ID in GitHub Actions.

  # The CI identity is only Owner of the app resource group, so it can't register
  # providers at subscription scope. bootstrap.sh registers the ones we need.
  resource_provider_registrations = "none"

  features {
    key_vault {
      # Purging needs subscription-level rights the CI identity doesn't have.
      # Vault names get a fresh random suffix after a destroy, so nothing collides.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = false
    }
  }
}

provider "azapi" {}
