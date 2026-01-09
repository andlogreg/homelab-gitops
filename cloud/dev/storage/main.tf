terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
  }
  backend "azurerm" {
    key = "homelab/cloud/dev/storage/terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

variable "storage_account_name" {
  description = "The name of the storage account. Must be globally unique."
  type        = string
}

module "storage" {
  source = "../../_modules/storage_account"

  storage_account_name = var.storage_account_name
  resource_group_name  = "rg-homelab-dev"

  # Common backup targets
  containers = ["cnpg-backups"]

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
