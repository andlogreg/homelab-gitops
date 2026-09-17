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

  # Lifecycle policy: TWO rules now. bound-blob-versions has always been here;
  # sweep-retired-generations is emitted on this account for the first time, because staging has
  # finally retired a generation. Until 2026-09-17 retired_generation_prefixes was empty and that
  # rule was not emitted at all, with a note here saying to set it "at the next rebuild that
  # actually retires one". What retired one was not a rebuild: the kopia repository password was
  # rotated, and since Velero cannot re-key a repository in place, a new password can only take
  # effect on a repository initialised under a new prefix. phoenix-staging-g1/ went cold that day
  # and phoenix-staging-g2/ became live.
  #
  # So the generation counter is not a rebuild counter. Anything that needs fresh kopia key
  # material advances it, and this list must be extended whenever it advances -- otherwise the
  # outgoing prefix sits here forever, still openable by a password that is no longer in use.
  #
  # (Only *-db-01 under cnpg-backups/ remains live and unretired: the Postgres backups are not
  # client-side encrypted, so no kopia key rotation touches them and their serverName did not move.)
  #
  # WARNING: the OLD repository password is the only key to everything under the retired prefix,
  # and it stays needed until this rule has finished clearing it -- 180d after the last write to
  # that prefix, so roughly 2027-03. Keep it until then, and do not delete those blobs by hand to
  # hurry it along: they are the only restore path for anything taken before the rotation.
  #
  # The old rule swept the live containers 30d after last write, on the premise that this sat safely
  # above the in-cluster Velero 20d TTL and CNPG 14d retention. The premise was false, because backup
  # blobs are never rewritten, and it destroyed this environment's kopia repository on 2026-08-13.
  # bound-blob-versions is not a return to that: it has no base_blob action, so it cannot delete a
  # current blob at all.
  #
  # enabled went back to true on 2026-09-06. It was false because an enabled policy with an empty
  # rule set is invalid rather than inert, and with no retired generation there was no rule to emit.
  # There is one now.
  #
  # This closes the gap this block used to describe: non-current versions under the LIVE prefixes
  # were pruned by nothing, because a version action is scoped by the same prefix_match as the
  # base_blob action beside it. Staging held 1,599 of them across both containers (1.517 GiB against
  # 1.238 GiB of live data) when this was measured on 2026-09-06, including 1,147 stranded under
  # phoenix-staging-g1/kopia/ by the 2026-09-05 in-place repository rebuild -- which emptied the
  # prefix and reused its name, so no per-generation cleanup would ever have reached them.
  lifecycle_management = {
    enabled                        = true
    cold_generation_retention_days = 180
    version_retention_days         = 180
    retired_generation_prefixes    = ["velero-backups/phoenix-staging-g1/"]
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
