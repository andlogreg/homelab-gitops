resource "azurerm_storage_account" "storage" {
  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier             = var.account_tier
  account_replication_type = var.account_replication_type

  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"
  is_hns_enabled             = var.is_hns_enabled
  tags                       = var.tags

  network_rules {
    default_action             = var.network_rules.default_action
    ip_rules                   = var.network_rules.ip_rules
    virtual_network_subnet_ids = var.network_rules.virtual_network_subnet_ids
    bypass                     = var.network_rules.bypass
  }

  blob_properties {
    versioning_enabled = var.blob_properties.versioning_enabled

    delete_retention_policy {
      days = var.blob_properties.delete_retention_policy_days
    }
  }

}


resource "azurerm_storage_container" "containers" {
  for_each              = toset(var.containers)
  name                  = each.key
  storage_account_id    = azurerm_storage_account.storage.id
  container_access_type = "private"
}
