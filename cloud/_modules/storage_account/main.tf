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

# Backup cleanup. Rule A flat-deletes the frozen pre-rebuild archives; Rule B deletes blobs in
# the live backup containers after N days since last modification, which sweeps cold/retired
# generations (a rebuilt cluster writes under a fresh prefix/serverName, so the old one goes cold).
resource "azurerm_storage_management_policy" "backup_lifecycle" {
  count              = var.lifecycle_management.enabled ? 1 : 0
  storage_account_id = azurerm_storage_account.storage.id

  # Rule A — frozen pre-rebuild archives (*-archive-pre-t12): flat delete.
  rule {
    name    = "delete-frozen-archives"
    enabled = true
    filters {
      prefix_match = ["velero-backups-archive-pre-t12", "cnpg-backups-archive-pre-t12"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.lifecycle_management.archive_retention_days
      }
    }
  }

  # Rule B — cold/retired generations in the live backup containers. The trailing slash keeps
  # this OFF the *-archive-pre-t12 containers (Rule A owns those) since their path is
  # "velero-backups-archive-…", not "velero-backups/…".
  rule {
    name    = "sweep-cold-generations"
    enabled = true
    filters {
      prefix_match = ["velero-backups/", "cnpg-backups/"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.lifecycle_management.cold_generation_retention_days
      }
    }
  }
}
