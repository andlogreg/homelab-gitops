terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
  }
  backend "azurerm" {
    key              = "homelab/cloud/dev/storage/terraform.tfstate"
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {}
}

variable "storage_account_name" {
  description = "The name of the storage account. Must be globally unique."
  type        = string
}

variable "keyvault_name" {
  description = "Name of the Key Vault to store secrets in."
  type        = string
}

module "storage" {
  source = "../../_modules/storage_account"

  storage_account_name = var.storage_account_name
  resource_group_name  = "rg-homelab-dev"

  # Common backup targets
  containers = ["cnpg-backups", "velero-backups"]

  tags = {
    environment = "dev"
    project     = "homelab"
  }
}

output "storage_account_id" {
  value = module.storage.id
}

output "blob_endpoint" {
  value = module.storage.primary_blob_endpoint
}

# Store secrets in Key Vault for Kubernetes to consume
data "azurerm_key_vault" "kv" {
  name                = var.keyvault_name
  resource_group_name = "rg-homelab-dev"
}

resource "azurerm_key_vault_secret" "storage_account_name" {
  name         = "azure-main-storage-account-name"
  value        = module.storage.name
  key_vault_id = data.azurerm_key_vault.kv.id
}

resource "azurerm_key_vault_secret" "storage_account_key" {
  name         = "azure-main-storage-account-key"
  value        = module.storage.primary_access_key
  key_vault_id = data.azurerm_key_vault.kv.id
}
