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
# ALMOST NO ARM ROLE, and the exception is named. These principals cannot call listKeys, edit the
# lifecycle policy, or change blob service properties. That also closes a trap in Velero: with
# neither `storageAccountKeyEnvVar` nor `useAAD` set it falls back to exchanging the Entra
# credential for the account key via listKeys. That fallback cannot succeed here.
#
# The one exception is Storage Blob Delegator on the Velero identity, added because the original
# "no ARM role at all" broke Velero's own inspection path -- see the block above that resource.
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
      display_name = "sp-homelab-staging-velero-backup"
      container    = "velero-backups"
    }
    cnpg = {
      display_name = "sp-homelab-staging-cnpg-backup"
      container    = "cnpg-backups"
    }
  }

  # WHEN THESE SECRETS DIE. Deliberately EARLIER than production's (2028-08-01) so staging fails
  # first and acts as the canary -- nothing currently alerts on a failed backup, so the two-month
  # gap is the only warning the production credential gets. Renewing is an edit to this date plus
  # an apply; create_before_destroy below means the new secret exists before the old is revoked.
  # NOTE the renewal is NOT free on the CNPG side: the barman sidecar reads its credential from
  # container env, which is fixed at pod start, so the PostgreSQL instances must be rolled for a
  # new secret to take effect. Velero re-reads its credentials file on its own and needs nothing.
  backup_secret_end_date = "2028-06-01T00:00:00Z"
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

# THE ONE ARM ROLE, and why it does not undo the paragraph above.
#
# WHAT BROKE. With only the container-scoped assignment, every Velero DownloadRequest failed
# `403 AuthorizationPermissionMismatch`, so `velero backup describe --details`, `velero backup
# logs`, `velero restore logs` and `velero backup download` all returned errors instead of data.
# Restores were never affected -- the plugin reads blobs directly and does not sign a URL -- which
# is exactly why this went unnoticed for five weeks after the identities moved to Entra auth. The
# cost is paid at the worst possible moment: during a real recovery you cannot read the restore's
# own log.
#
# WHY. Signing a download URL under Entra auth means a user delegation SAS, which needs
# `Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action`. Storage Blob
# Data Contributor DOES include that action -- the role was never the problem, the SCOPE was.
# Get User Delegation Key acts at the level of the storage account, so Microsoft requires the
# action to be assigned at account, resource group or subscription scope; a container-scoped
# assignment can never satisfy it. Microsoft documents this exact remedy for this exact shape:
# a principal holding container-scoped data access is additionally granted Storage Blob Delegator
# at account scope.
#
# WHY IT DOES NOT WIDEN THE BLAST RADIUS, which is the only question that matters here.
#   1. Storage Blob Delegator grants exactly ONE action and no dataActions
#      (`az role definition list --name "Storage Blob Delegator" --query "[0].permissions"`).
#      No listKeys, no lifecycle policy, no blob service properties. The Velero account-key
#      fallback trap described above stays shut.
#   2. A user delegation SAS is bounded by the INTERSECTION of the requesting principal's RBAC and
#      the permissions written into the token. Delegation cannot mint authority the principal does
#      not already hold, so this identity can still only sign URLs over its own container. Account
#      SCOPE on the delegation action is not account ACCESS.
#
# VELERO ONLY. The barman path never issues a SAS -- CNPG reads and writes blobs directly -- so the
# CNPG identity is deliberately left without this role. Grant it only if something there starts
# needing signed URLs, and record why.
resource "azurerm_role_assignment" "velero_blob_delegator" {
  scope                = module.storage.id
  role_definition_name = "Storage Blob Delegator"
  principal_id         = azuread_service_principal.backup["velero"].object_id
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
