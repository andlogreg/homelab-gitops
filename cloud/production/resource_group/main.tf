terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
  }
  backend "azurerm" {
    key              = "homelab/cloud/production/resource_group/terraform.tfstate"
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "my-rg" {
  name     = "rg-homelab-production"
  location = var.location
  tags     = var.tags
}
