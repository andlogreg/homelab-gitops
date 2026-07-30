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
    Azure Blob lifecycle management for backup cleanup.
    Rule A flat-deletes the frozen *-archive-pre-t12 containers after archive_retention_days.
    Rule B deletes blobs in the live backup containers (velero-backups/, cnpg-backups/) after
    cold_generation_retention_days since last modification. This sweeps retired generations
    (a rebuilt cluster writes under a fresh prefix/serverName, so the old one goes cold) and
    also bounds how long backups survive after a total cluster loss, so set it above the
    in-cluster Velero TTL (20d) and CNPG retention (14d). enabled = false disables the policy.

    version_retention_days prunes non-current blob versions in both rules. It only does anything
    when blob_properties.versioning_enabled is true, and it is the reason versioning must not be
    enabled without this policy: nothing else deletes a version.
  EOT
  type = object({
    enabled                        = bool
    archive_retention_days         = number
    cold_generation_retention_days = number
    version_retention_days         = number
  })
  default = {
    enabled                        = false
    archive_retention_days         = 30
    cold_generation_retention_days = 30
    version_retention_days         = 30
  }
}

variable "tags" {
  description = "Tags to assign to the resource."
  type        = map(string)
  default     = {}
}
