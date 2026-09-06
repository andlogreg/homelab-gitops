variable "location" {
  description = "Azure region"
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
}

variable "storage_account_name" {
  description = "Name of the Storage Account. Must be unique."
  type        = string
}

variable "account_tier" {
  description = "Tier to use for this storage account."
  type        = string
  default     = "Standard"
}

variable "account_replication_type" {
  description = "Replication to use for this storage account."
  type        = string
  default     = "LRS"
}

variable "is_hns_enabled" {
  description = "Is Hierarchical Namespace enabled."
  type        = bool
  default     = false
}

variable "shared_access_key_enabled" {
  description = <<-EOT
    Whether Shared Key (account key) auth is permitted at all. Defaults to true so existing
    accounts that still have a consumer on the key are unaffected. Set to false at creation for
    any account that should never have a working key-based credential from birth.
  EOT
  type        = bool
  default     = true
}

variable "containers" {
  description = "List of containers to create in the storage account."
  type        = list(string)
  default     = []
}

variable "network_rules" {
  description = <<-EOT
    Network rules for the storage account. Leave null (the default) to leave the account
    open, which is what a network_rules block cannot express: the provider requires
    default_action = "Deny" plus at least one ip_rule or subnet id, and silently declines
    to record an all-permissive block, so declaring one yields a diff that never converges.
    Set this only to actually restrict access.
  EOT
  type = object({
    default_action             = string
    ip_rules                   = list(string)
    virtual_network_subnet_ids = list(string)
    bypass                     = list(string)
  })
  default = null
}

variable "blob_properties" {
  description = <<-EOT
    Blob-level data protection for the storage account.

    container_delete_retention_policy_days is the load-bearing one. Blob soft-delete and versioning
    are both reachable through the data-plane Set Blob Service Properties API, which accepts Shared
    Key auth — so anyone holding the storage account key can switch them off. Container soft-delete
    is ARM-only and they cannot. That asymmetry is the point: deleting a container also destroys the
    soft-deleted blobs inside it, so without this setting a single container delete takes every
    backup with it and leaves nothing to restore. Self-bounding (Azure purges the deleted container
    after this many days), so it needs no lifecycle rule and is safe to leave on everywhere.

    versioning_enabled covers the case soft-delete does not: a blob OVERWRITTEN rather than deleted.
    Only turn it on where lifecycle_management is also enabled — versions are pruned by its
    version_retention_days rule, and without that they accumulate forever.
  EOT
  type = object({
    versioning_enabled                     = bool
    delete_retention_policy_days           = number
    container_delete_retention_policy_days = number
  })
  default = {
    versioning_enabled                     = false
    delete_retention_policy_days           = 7
    container_delete_retention_policy_days = 30
  }
}

variable "lifecycle_management" {
  description = <<-EOT
    Azure Blob lifecycle management for backup cleanup. Two rules, with strictly separated powers:

      sweep-retired-generations  deletes BLOBS under retired_generation_prefixes after
                                 cold_generation_retention_days since last modification. Not
                                 emitted at all when that list is empty.
      bound-blob-versions        deletes non-current VERSIONS anywhere in `containers` after
                                 version_retention_days since the blob was first written. Emitted
                                 only when blob_properties.versioning_enabled is true, and it
                                 carries no base_blob action, so it can never delete live data.

    retired_generation_prefixes is an EXPLICIT list of "<container>/<path>/" prefixes belonging to
    generations a rebuild has retired. It defaults to empty, and the live generation must never
    appear in it. Retiring a generation is a deliberate act performed by a human during a rebuild,
    not something a lifecycle rule can infer -- see the comment on the rule in main.tf for the
    incident that established this.

    cold_generation_retention_days is the window applied to those named prefixes. It no longer
    bounds how long backups survive a total cluster loss: with no rule on the live prefix that
    window is now indefinite, which serves the disaster-recovery purpose strictly better than
    deleting on a timer. Storage stays bounded because Velero TTL GC, kopia repository maintenance
    and barman retention all prune the live generation from inside the cluster. enabled = false
    disables the policy entirely.

    version_retention_days is a protection horizon measured from the blob's FIRST WRITE, not a
    fixed window after a version becomes non-current -- Azure ages a previous version from "when
    the blob was first written (not when the version became a previous version)". So the undo a
    given blob actually gets is (version_retention_days - that blob's lifetime), and it differs by
    blob class: barman WAL and base backups die at ~14d and Velero metadata at ~20d, so those keep
    nearly the whole window, while a kopia content blob pinned by deduplication for months keeps
    correspondingly less. Set it longer than the detection lag you are willing to tolerate for a
    destructive accident, since the 7-day blob soft-delete already covers anything noticed sooner.

    It applies to both rules, at the same value on purpose: they overlap on the retired prefixes,
    and Azure does not define which threshold wins when two rules specify the same action, so
    identical values remove the question. Nothing else on the account deletes a version -- which is
    why versioning must not be enabled without this policy.
  EOT
  type = object({
    enabled                        = bool
    cold_generation_retention_days = number
    version_retention_days         = number
    retired_generation_prefixes    = list(string)
  })
  default = {
    enabled                        = false
    cold_generation_retention_days = 30
    version_retention_days         = 30
    retired_generation_prefixes    = []
  }

  # The guard that would have caught the 2026-08 incident at plan time instead of five weeks
  # later, by which point the rule had made staging's kopia repository undecryptable. A retired
  # prefix names a generation, so it always has a segment BELOW the container:
  # "velero-backups/kopia/" is a generation; "velero-backups/" is the whole live backup surface
  # wearing the same shape.
  validation {
    condition = alltrue([
      for p in var.lifecycle_management.retired_generation_prefixes :
      length(compact(split("/", p))) >= 2
    ])
    error_message = join(" ", [
      "Each retired_generation_prefixes entry must name a path BELOW a container",
      "(e.g. \"velero-backups/kopia/\"), never a bare container root such as",
      "\"velero-backups/\". A bare container root puts the LIVE generation under a",
      "days-since-modification delete, which is what destroyed staging's kopia repository",
      "on 2026-08-13. Version pruning is handled separately by bound-blob-versions.",
    ])
  }
}

variable "tags" {
  description = "Tags to assign to the resource."
  type        = map(string)
  default     = {}
}
