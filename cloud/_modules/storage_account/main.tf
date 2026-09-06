resource "azurerm_storage_account" "storage" {
  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier             = var.account_tier
  account_replication_type = var.account_replication_type

  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"
  is_hns_enabled             = var.is_hns_enabled
  shared_access_key_enabled  = var.shared_access_key_enabled
  tags                       = var.tags

  # Emitted only when the rules actually restrict something (see the variable's description).
  dynamic "network_rules" {
    for_each = var.network_rules == null ? [] : [var.network_rules]
    content {
      default_action             = network_rules.value.default_action
      ip_rules                   = network_rules.value.ip_rules
      virtual_network_subnet_ids = network_rules.value.virtual_network_subnet_ids
      bypass                     = network_rules.value.bypass
    }
  }

  blob_properties {
    versioning_enabled = var.blob_properties.versioning_enabled

    delete_retention_policy {
      days = var.blob_properties.delete_retention_policy_days
    }

    # The only data-protection setting here that a holder of the account key cannot turn off --
    # see the variable description. Without it, deleting a container permanently destroys the
    # soft-deleted blobs inside it.
    container_delete_retention_policy {
      days = var.blob_properties.container_delete_retention_policy_days
    }
  }

}


resource "azurerm_storage_container" "containers" {
  for_each              = toset(var.containers)
  name                  = each.key
  storage_account_id    = azurerm_storage_account.storage.id
  container_access_type = "private"
}

# Backup cleanup. One rule, and it deletes blobs only under the EXPLICITLY NAMED retired
# generation prefixes. It may never match a live one.
#
# A second rule, "delete-frozen-archives", used to sit above this one. It flat-deleted the frozen
# pre-rebuild archive containers (*-archive-pre-t12) on a days-since-modification window, it did
# its job, and it was removed once those containers were deleted. A lifecycle rule whose targets
# no longer exist is not free: it is a standing claim about behaviour that nothing exercises, and
# on this account it would have been the one rule a reader could not test. This is also the family
# of rule whose sibling logic destroyed a live kopia repository once -- see below -- so carrying
# one fewer of them is worth something by itself.
resource "azurerm_storage_management_policy" "backup_lifecycle" {
  count              = var.lifecycle_management.enabled ? 1 : 0
  storage_account_id = azurerm_storage_account.storage.id

  # Retired generations, NAMED EXPLICITLY.
  #
  # This rule used to carry the bare prefixes "velero-backups/" and "cnpg-backups/" and infer
  # "retired" from days-since-last-modification, on the assumption that a live generation is
  # rewritten often enough to stay fresh. That assumption is false, and it destroyed real backups.
  #
  # Backup formats are deliberately WRITE-ONCE. None of these is ever rewritten after creation:
  #   - kopia's format blob (kopia.repository, kopia.blobcfg), written at repository init. It
  #     carries the encryption parameters and key-derivation salt, so losing it does not merely
  #     unindex the repository, it makes every remaining blob undecryptable.
  #   - kopia's content-addressed data blobs (p*), which today's snapshot still references
  #     precisely BECAUSE deduplication declined to write them again.
  #   - barman's WAL segments and base-backup tarballs.
  #   - PostgreSQL timeline history files (NNNNNNNN.history.gz), written once at promotion and
  #     never pruned by barman's own retention.
  # Azure can only see when a blob was last WRITTEN, never whether it is still NEEDED, so on this
  # kind of data the two diverge completely and the rule deletes live backups on a timer.
  #
  # What it cost: staging's kopia repository was initialised ~2026-07-14 and its format
  # blob aged out at exactly 30 days on 2026-08-13, taking every staging snapshot with it while
  # BackupRepository still reported Ready and 21 consecutive dailies reported PartiallyFailed. The
  # same thing had already happened to production's retired g0 repos at 180 days. Blob versioning
  # is no protection: a version's age counts from version creation, so a write-once blob's version
  # is born older than version_retention_days.
  #
  # The live generation is therefore left to the mechanisms that actually know what is still
  # referenced -- Velero TTL GC plus kopia repository maintenance, and barman retention -- and this
  # rule only ever touches prefixes a human named when a rebuild retired them. Adding that prefix
  # is a step in the rebuild runbook. Forgetting it wastes storage; the old behaviour destroyed
  # backups, so this fails in the cheaper direction.
  #
  # The for_each is load-bearing: an Azure lifecycle rule with an empty prefix_match filter matches
  # the ENTIRE account, so an empty list must emit no rule rather than an unfiltered one.
  dynamic "rule" {
    for_each = length(var.lifecycle_management.retired_generation_prefixes) > 0 ? [1] : []
    content {
      name    = "sweep-retired-generations"
      enabled = true
      filters {
        prefix_match = var.lifecycle_management.retired_generation_prefixes
        blob_types   = ["blockBlob"]
      }
      actions {
        base_blob {
          delete_after_days_since_modification_greater_than = var.lifecycle_management.cold_generation_retention_days
        }
        # No-op unless versioning is enabled. Nothing else ever deletes a non-current version.
        version {
          delete_after_days_since_creation = var.lifecycle_management.version_retention_days
        }
      }
    }
  }
}
