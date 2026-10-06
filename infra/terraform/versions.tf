terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.8"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.13"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # Remaining settings (storage account, container, key) are passed with
  # -backend-config at init time; see infra/README.md.
  backend "azurerm" {
    use_azuread_auth = true
  }
}
