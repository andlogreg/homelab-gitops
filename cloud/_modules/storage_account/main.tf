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

# Backup cleanup. Two rules, and the split between them is the point:
#
#   sweep-retired-generations  deletes BLOBS, and only under the EXPLICITLY NAMED retired
#                              generation prefixes. It may never match a live one.
#   bound-blob-versions        deletes non-current VERSIONS, across the whole backup surface.
#                              It has no base_blob action, so it cannot touch live data.
#
# Deleting a blob and deleting a version are different powers, and only the first one is dangerous
# here. Conflating them is what left version growth unbounded until 2026-09-06: a version action is
# scoped by the same prefix_match as the base_blob action beside it, so putting version pruning
# inside the retired-generation rule silently meant "prune versions under retired prefixes only".
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
        # Load-bearing, not decorative: "a lifecycle management policy will not delete the current
        # version of a blob until any previous versions or snapshots associated with that blob have
        # been deleted" (Azure lifecycle policy-structure doc). Retired prefixes acquire versions
        # like any other, so without this action the base_blob delete above would stall on every
        # blob that has one, and the retired generation would never finish going away.
        #
        # Same window as bound-blob-versions below, deliberately. The two rules overlap on the
        # retired prefixes, and Azure does not define which wins when two rules specify the same
        # action with different thresholds -- identical thresholds make the overlap a no-op instead
        # of a question nobody can answer from the docs.
        version {
          delete_after_days_since_creation = var.lifecycle_management.version_retention_days
        }
      }
    }
  }

  # Bound non-current version growth, across the WHOLE backup surface.
  #
  # This rule has NO base_blob action and must never acquire one. That is the entire reason it can
  # safely carry the bare container prefixes that destroyed staging's kopia repository in the hands
  # of the old sweep-cold-generations rule: a version action cannot touch a current blob. Azure
  # scopes the version action by the same prefix_match as base_blob, which is exactly why the
  # retired-generation rule above could never prune the live generation's versions -- its filter
  # names retired prefixes only.
  #
  # Why the container roots rather than a list of live prefixes. A named list would have to be
  # updated at every rebuild, and forgetting it is silent: versions simply start accumulating again
  # with no symptom until someone enumerates the account. The container roots need no maintenance,
  # cover the live generation, the retired ones, and the orphans left behind by an in-place
  # repository rebuild that reuses its prefix (staging, 2026-09-05) -- which no per-generation list
  # would ever catch.
  #
  # Why this window buys real protection despite the write-once trap. Azure ages a previous version
  # from when the blob was FIRST WRITTEN, not from when it became non-current, so the protection a
  # blob actually gets is (window - its lifetime). Barman WAL and base backups are deleted by CNPG
  # retention at ~14d and Velero metadata at ~20d, so those keep ~160 days of undo -- and they are
  # ~81% of the stored bytes. Long-lived kopia content blobs, pinned by deduplication for months,
  # get correspondingly less. It is a protection horizon measured from birth, not a fixed window.
  dynamic "rule" {
    for_each = var.blob_properties.versioning_enabled ? [1] : []
    content {
      name    = "bound-blob-versions"
      enabled = true
      filters {
        prefix_match = [for c in var.containers : "${c}/"]
        blob_types   = ["blockBlob"]
      }
      actions {
        version {
          delete_after_days_since_creation = var.lifecycle_management.version_retention_days
        }
      }
    }
  }

  # Azure requires at least one rule in a policy: an enabled policy with an empty rule set is
  # INVALID, not inert. Both rules above are conditional, so this combination produces an empty
  # policy and a confusing API error at apply time rather than at plan time.
  lifecycle {
    precondition {
      condition = !var.lifecycle_management.enabled || (
        length(var.lifecycle_management.retired_generation_prefixes) > 0 ||
        var.blob_properties.versioning_enabled
      )
      error_message = join(" ", [
        "lifecycle_management.enabled is true but no rule would be emitted:",
        "retired_generation_prefixes is empty and versioning_enabled is false.",
        "Azure rejects a policy with zero rules -- set enabled = false instead.",
      ])
    }
  }
}
