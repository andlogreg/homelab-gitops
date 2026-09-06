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
    key              = "homelab/cloud/production/storage/terraform.tfstate"
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
  resource_group_name  = "rg-homelab-production"

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

  # Backup cleanup, two rules with separated powers: blobs under the NAMED retired generations are
  # deleted 180d after last write, and non-current VERSIONS anywhere in the two backup containers
  # are deleted 180d after the blob was first written.
  #
  # The previous version of this comment claimed the 180d window was the total-loss recovery
  # window -- "~6 months to rebuild and restore before the latest backups are removed" -- and that
  # the rule "only bites a generation that has gone cold". Both were wrong, and the second one had
  # already fired here: it deleted the kopia format blobs of the retired g0 repos for homarr,
  # linkding and mealie, which are now unopenable. See the rule's comment in the module.
  #
  # Nothing sweeps the live generation any more, so the total-loss window is now indefinite --
  # strictly better for the purpose the 180d figure was chosen to serve.
  #
  # The prefixes below are the generations the 2026-07-12/13 rebuild retired, verified against blob
  # storage on 2026-09-04 (1751 blobs, ~670 MB, nothing written since 2026-07-13). The live
  # generation -- velero-backups/phoenix-production-g1/, and cnpg-backups/{litellm,mealie}/*-db-01
  # and health/health-db-00 -- must never appear here.
  # version_retention_days was 30 until 2026-09-06 and pruned nothing on this account: a version
  # action is scoped by the same prefix_match as the base_blob action beside it, so it only ever
  # covered the retired prefixes. Live versions accumulated from the day versioning was switched on
  # (2026-07-30) -- 14,039 of them, 3.318 GiB across both containers, growing ~46 GiB/yr estate-wide
  # and compounding. bound-blob-versions now covers the container roots, so the number applies to
  # the whole account. 180d is set against detection lag, not cost: the 7-day blob soft-delete
  # already covers anything noticed within a week, and this buys undo for a destructive accident
  # nobody catches for up to six months. Production alerting (VeleroRepoMaintenanceStale at 6h,
  # VeleroBackupCapturedNothing, four CNPG rules) makes that a wide margin.
  lifecycle_management = {
    enabled                        = true
    cold_generation_retention_days = 180
    version_retention_days         = 180
    retired_generation_prefixes = [
      "velero-backups/backups/",
      "velero-backups/kopia/",
      "cnpg-backups/litellm/litellm-db-00/",
      "cnpg-backups/mealie/mealie-db-00/",
    ]
  }

  tags = {
    environment = "production"
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
  resource_group_name = "rg-homelab-production"
}

resource "azurerm_key_vault_secret" "storage_account_name" {
  name         = "azure-main-storage-account-name"
  value        = module.storage.name
  key_vault_id = data.azurerm_key_vault.kv.id
}
