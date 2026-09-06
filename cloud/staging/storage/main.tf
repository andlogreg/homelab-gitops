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
    key              = "homelab/cloud/staging/storage/terraform.tfstate"
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {}

  # Mandatory, not stylistic: with shared-key auth disabled below, the provider's own
  # account-level data-plane call -- the post-create/refresh "wait for the Blob Service to
  # become available" poll -- is NOT ARM and authenticates with the account key. Without
  # this it fails with KeyBasedAuthenticationNotPermitted and taints a perfectly healthy
  # account, after which the next plan proposes REPLACING it.
  storage_use_azuread = true
}

provider "azuread" {}

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
  resource_group_name  = "rg-homelab-staging"

  # Common backup targets
  containers = ["cnpg-backups", "velero-backups"]

  # No Shared Key auth. Every consumer now authenticates with a container-scoped Entra
  # identity, so the account key has no consumer left -- and a key that cannot be used is
  # inert even if it leaks, which no amount of soft-delete or versioning achieves.
  # Reading blobs by hand requires --auth-mode login; omitting it is refused, by design.
  shared_access_key_enabled = false

  # Data protection. Container soft-delete is the one that closes the total-loss case: it is the
  # only setting of the three that a holder of the storage account key cannot switch off, and
  # deleting a container is what destroys soft-deleted blobs. Versioning covers the variant
  # soft-delete misses -- blobs OVERWRITTEN rather than deleted -- and is safe to enable here
  # because lifecycle_management below prunes the versions.
  blob_properties = {
    versioning_enabled                     = true
    delete_retention_policy_days           = 7
    container_delete_retention_policy_days = 30
  }

  # Backup cleanup: delete the frozen archives after 30d. Nothing sweeps the live backup
  # containers -- see the Rule B comment in the module. The old rule swept them 30d after last
  # write, on the premise that this was safely above the in-cluster Velero 20d TTL and CNPG 14d
  # retention; the premise was false, because backup blobs are never rewritten, and it destroyed
  # this environment's kopia repository on 2026-08-13.
  #
  # The list is empty because staging genuinely has no retired generation: only
  # phoenix-staging-g1 under velero-backups/, only *-db-01 under cnpg-backups/. Populate it at the
  # next rebuild, when one is actually retired.
  lifecycle_management = {
    enabled                        = true
    archive_retention_days         = 30
    cold_generation_retention_days = 30
    version_retention_days         = 30
    retired_generation_prefixes    = []
  }

  tags = {
    environment = "staging"
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
  resource_group_name = "rg-homelab-staging"
}

resource "azurerm_key_vault_secret" "storage_account_name" {
  name         = "azure-main-storage-account-name"
  value        = module.storage.name
  key_vault_id = data.azurerm_key_vault.kv.id
}
