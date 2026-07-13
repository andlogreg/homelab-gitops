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
  description = "Network rules for the storage account."
  type = object({
    default_action             = string
    ip_rules                   = list(string)
    virtual_network_subnet_ids = list(string)
    bypass                     = list(string)
  })
  default = {
    default_action             = "Allow"
    ip_rules                   = []
    virtual_network_subnet_ids = []
    bypass                     = ["AzureServices"]
  }
}

variable "blob_properties" {
  description = "Blob properties for the storage account."
  type = object({
    versioning_enabled           = bool
    delete_retention_policy_days = number
  })
  default = {
    versioning_enabled           = false
    delete_retention_policy_days = 7
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
  EOT
  type = object({
    enabled                        = bool
    archive_retention_days         = number
    cold_generation_retention_days = number
  })
  default = {
    enabled                        = false
    archive_retention_days         = 30
    cold_generation_retention_days = 30
  }
}

variable "tags" {
  description = "Tags to assign to the resource."
  type        = map(string)
  default     = {}
}
