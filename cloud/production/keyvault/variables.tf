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
    environment = "production"
  }
}

variable "keyvault_name" {
  description = "Key vault name"
  type        = string
}
