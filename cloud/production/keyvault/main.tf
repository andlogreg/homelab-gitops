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
    key = "homelab/cloud/production/keyvault/terraform.tfstate"
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
  resource_group_name = "rg-homelab-production"
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

##### ESO identity — Key Vault access via Workload Identity Federation #####
# No client secret: the federated credential (oidc.tf) lets ESO's ServiceAccount
# token be exchanged for a Key Vault token. The app/SP below only carry the
# identity + the Key Vault role assignment.

resource "azuread_application" "eso" {
  display_name = "sp-homelab-production-eso"
  owners       = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "eso" {
  client_id = azuread_application.eso.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azurerm_role_assignment" "eso_kv_secrets" {
  scope                = module.keyvault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azuread_service_principal.eso.object_id
}

output "eso_sp_client_id" {
  value = azuread_application.eso.client_id
}

output "azure_tenant_id" {
  value = data.azuread_client_config.current.tenant_id
}
