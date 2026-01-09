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

variable "tags" {
  description = "Tags to assign to the resource."
  type        = map(string)
  default     = {}
}
