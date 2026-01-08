terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
  }
  backend "azurerm" {
    key = "homelab/cloud/dev/keyvault/terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "my-rg" {
  name     = "rg-homelab-dev"
  location = var.location
  tags     = var.tags
}

module "keyvault" {
  source = "../../_modules/keyvault"

  keyvault_name       = var.keyvault_name
  resource_group_name = azurerm_resource_group.my-rg.name
  location            = var.location
  sku_name            = "standard"

  network_acls = {
    bypass                     = "AzureServices"
    default_action             = "Allow"
    ip_rules                   = []
    virtual_network_subnet_ids = []
  }

  tags = var.tags
}

output "keyvault_id" {
  value = module.keyvault.id
}

output "keyvault_uri" {
  value = module.keyvault.vault_uri
}
