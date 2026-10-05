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
    key              = "homelab/cloud/production/personal-data/terraform.tfstate"
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {}

  # Shared Key auth is off on this account, so the provider's own data-plane calls must use Entra.
  storage_use_azuread = true
}

provider "azuread" {}

variable "storage_account_name" {
  description = "The name of the storage account. Must be globally unique."
  type        = string
}

# The offsite restic repository for the personal-data hub (photos and a file archive). An account of
# its own, so the hub's credential reaches nothing else in the estate.
module "storage" {
  source = "../../_modules/storage_account"

  storage_account_name = var.storage_account_name
  resource_group_name  = "rg-homelab-production"

  containers = ["restic"]

  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false

  # The account default rather than restic's per-run tier flag, so no run can forget it.
  access_tier = "Cold"

  # 90 days: for data older than the version window, soft-delete is the only undo.
  blob_properties = {
    versioning_enabled                     = true
    delete_retention_policy_days           = 90
    container_delete_retention_policy_days = 90
  }

  # No retired generations, so only bound-blob-versions is emitted. 180 days also outlasts the Cold
  # tier's 90-day minimum, so a deleted blob is never billed early.
  lifecycle_management = {
    enabled                        = true
    cold_generation_retention_days = 180
    version_retention_days         = 180
    retired_generation_prefixes    = []
  }

  tags = {
    project     = "homelab"
    environment = "production"
    component   = "personal-data"
  }
}

output "storage_account_id" {
  value = module.storage.id
}

output "blob_endpoint" {
  value = module.storage.primary_blob_endpoint
}
