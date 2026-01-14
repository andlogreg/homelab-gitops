terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.0"
    }
  }
  backend "azurerm" {
    key = "homelab/cloud/helios/keyvault/terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

provider "azuread" {}

data "azuread_client_config" "current" {}

##### Keyvault #####

module "keyvault" {
  source = "../../_modules/keyvault"

  keyvault_name       = var.keyvault_name
  resource_group_name = "rg-homelab-helios"
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

##### Keyvault Service Principal #####

resource "azuread_application" "eso" {
  display_name = "sp-homelab-helios-eso"
  owners       = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "eso" {
  client_id = azuread_application.eso.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal_password" "eso" {
  service_principal_id = azuread_service_principal.eso.id
}

resource "azurerm_role_assignment" "eso_kv_secrets" {
  scope                = module.keyvault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azuread_service_principal.eso.object_id
}

output "eso_sp_client_id" {
  value = azuread_application.eso.client_id
}

output "eso_sp_client_secret" {
  value     = azuread_service_principal_password.eso.value
  sensitive = true
}

output "azure_tenant_id" {
  value = data.azuread_client_config.current.tenant_id
}
