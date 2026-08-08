terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
  }
  backend "azurerm" {
    key              = "homelab/cloud/production/health-archive/terraform.tfstate"
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {}

  # Shared Key auth is off on this account, so the provider's own data-plane calls (container
  # creation, the post-create "is the blob service up" poll) must use the same Entra credential
  # as everything else here, not fall back to fetching the account key.
  storage_use_azuread = true
}

data "azurerm_client_config" "current" {}

variable "storage_account_name" {
  description = "The name of the storage account. Must be globally unique."
  type        = string
}

# A dedicated account, separate from the backup accounts, because the backup accounts' lifecycle
# rule deletes on days-since-modification -- correct for backups, which churn, and exactly wrong
# for an archive that is by definition never modified. Reuses rg-homelab-production rather than a
# new resource group: the separate account is the isolation this needs, and a new RG would be
# infrastructure this doesn't.
module "storage" {
  source = "../../_modules/storage_account"

  storage_account_name = var.storage_account_name
  resource_group_name  = "rg-homelab-production"

  containers = ["health-archive"]

  # Shared Key auth disabled from birth -- unlike the backup accounts, this one never has a
  # working account key to begin with, so there is no later cutover needed.
  shared_access_key_enabled = false

  # Blob versioning + soft-delete. No lifecycle_management policy: retention is indefinite, on
  # purpose -- this account holds a write-once archive, so there should be no overwrites
  # generating blob versions for a pruning rule to clean up. If versions start accumulating,
  # that itself is the signal something is re-uploading over existing blobs.
  blob_properties = {
    versioning_enabled                     = true
    delete_retention_policy_days           = 30
    container_delete_retention_policy_days = 30
  }

  tags = {
    project     = "homelab"
    environment = "production"
    component   = "health-archive"
  }
}

output "storage_account_id" {
  value = module.storage.id
}

output "blob_endpoint" {
  value = module.storage.primary_blob_endpoint
}

# Container-scoped, not account-scoped, and via Entra rather than the (disabled) account key.
# There is exactly one container and one consumer here -- the operator's own identity, uploading
# archives by hand -- so this is the whole access story for this account. No service principal:
# nothing automated touches this account, only a human running `az login`.
resource "azurerm_role_assignment" "operator_blob_data" {
  scope                = module.storage.container_ids["health-archive"]
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
