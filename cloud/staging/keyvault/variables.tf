variable "location" {
  description = "Azure region"
  type        = string
  default     = "westeurope"
}

variable "tags" {
  description = "A mapping of tags to assign to the resources."
  type        = map(string)
  default = {
    project     = "homelab"
    environment = "staging"
  }
}

variable "keyvault_name" {
  description = "Key vault name"
  type        = string
}

variable "oidc_storage_account_name" {
  description = "Globally-unique name for the public storage account that hosts the ESO OIDC discovery doc + JWKS (Workload Identity Federation). Lowercase alphanumeric, 3-24 chars."
  type        = string
}
