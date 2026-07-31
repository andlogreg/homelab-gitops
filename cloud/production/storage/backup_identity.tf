# Container-scoped Entra identities for the backup path.
#
# WHAT THIS REPLACES. Until now both backup consumers authenticated with the storage ACCOUNT KEY,
# which carries read/write/delete over every container. Container soft-delete already made a
# deleted container recoverable, but it does nothing about the other half: a holder of the account
# key can turn OFF blob soft-delete and versioning (both are data-plane settings) and then delete
# every blob individually, in a container that was never deleted. These identities close that.
#
# TWO IDENTITIES, NOT ONE, deliberately. Each holds Storage Blob Data Contributor on exactly ONE
# container, so a compromise of the Velero path cannot reach the CNPG backups and vice versa.
#
# NO ARM ROLE AT ALL, also deliberately. Without one, these principals cannot call listKeys, edit
# the lifecycle policy, or change blob service properties. It also closes a trap in Velero: with
# neither `storageAccountKeyEnvVar` nor `useAAD` set it falls back to exchanging the Entra
# credential for the account key via listKeys. That fallback cannot succeed here.
#
# CLIENT SECRETS, NOT WORKLOAD IDENTITY. Federated identity needs a projected ServiceAccount token
# volume, and neither consumer can mount one: the Velero BSL takes a credentials file, and the
# barman ObjectStore's instanceSidecarConfiguration exposes `env` only, no volumes. WIF would
# therefore cost a standing cluster-wide azure-workload-identity webhook to avoid rotating one
# scoped secret -- the wrong side of that trade here. Revisit if the webhook ever arrives anyway.

data "azuread_client_config" "current" {}

locals {
  # Container names must match keys of module.storage.container_ids.
  backup_identities = {
    velero = {
      display_name = "sp-homelab-production-velero-backup"
      container    = "velero-backups"
    }
    cnpg = {
      display_name = "sp-homelab-production-cnpg-backup"
      container    = "cnpg-backups"
    }
  }

  # WHEN THESE SECRETS DIE. Two months AFTER staging's (2028-06-01), on purpose: nothing currently
  # alerts on a failed backup, so staging expiring first is the only warning this credential gets.
  # If staging's backups break, production is two months from the same fate -- treat it as the page
  # that no monitoring is sending. Renewing is an edit to this date plus an apply;
  # create_before_destroy below means the new secret exists before the old is revoked.
  # NOTE the renewal is NOT free on the CNPG side: the barman sidecar reads its credential from
  # container env, which is fixed at pod start, so the PostgreSQL instances must be rolled for a
  # new secret to take effect. Velero re-reads its credentials file on its own and needs nothing.
  backup_secret_end_date = "2028-08-01T00:00:00Z"
}

resource "azuread_application" "backup" {
  for_each     = local.backup_identities
  display_name = each.value.display_name
  owners       = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "backup" {
  for_each  = local.backup_identities
  client_id = azuread_application.backup[each.key].client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_password" "backup" {
  for_each       = local.backup_identities
  application_id = azuread_application.backup[each.key].id
  display_name   = "backup-path credential"
  end_date       = local.backup_secret_end_date

  # Azure allows several passwords on one app registration, so the replacement can be minted
  # before the old one is revoked. Without this, changing end_date leaves a window with no valid
  # credential at all.
  lifecycle {
    create_before_destroy = true
  }
}

# The whole point: Storage Blob Data Contributor on ONE container, not on the account.
resource "azurerm_role_assignment" "backup_container" {
  for_each             = local.backup_identities
  scope                = module.storage.container_ids[each.value.container]
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.backup[each.key].object_id
}

# The operator's own identity needs a data-plane role too, and did NOT have one: subscription
# ownership is control-plane and grants no blob access, so every hands-on check so far has gone
# through --account-key. Once shared-key auth is disabled on this account, `az storage blob list
# --auth-mode login` is the ONLY way left to confirm by hand that a WAL segment or a backup blob
# actually landed -- and that check is the whole basis for trusting the backup path. Account-scoped
# on purpose: this is an interactive human identity behind MFA, not a static secret held by a
# workload, and it needs to see every container to be useful for diagnosis.
resource "azurerm_role_assignment" "operator_blob_data" {
  scope                = module.storage.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azuread_client_config.current.object_id
}

# Published for ESO. The tenant ID is not a secret, but it travels with the other two so the
# ExternalSecret templates stay uniform.
resource "azurerm_key_vault_secret" "backup_identity_client_id" {
  for_each     = local.backup_identities
  name         = "azure-backup-${each.key}-client-id"
  value        = azuread_application.backup[each.key].client_id
  key_vault_id = data.azurerm_key_vault.kv.id
}

resource "azurerm_key_vault_secret" "backup_identity_client_secret" {
  for_each     = local.backup_identities
  name         = "azure-backup-${each.key}-client-secret" # pragma: allowlist secret
  value        = azuread_application_password.backup[each.key].value
  key_vault_id = data.azurerm_key_vault.kv.id
}

resource "azurerm_key_vault_secret" "azure_tenant_id" {
  name         = "azure-tenant-id"
  value        = data.azuread_client_config.current.tenant_id
  key_vault_id = data.azurerm_key_vault.kv.id
}

output "backup_identity_client_ids" {
  description = "Client IDs of the backup identities, for cross-checking what the cluster is using."
  value       = { for key, app in azuread_application.backup : key => app.client_id }
}
