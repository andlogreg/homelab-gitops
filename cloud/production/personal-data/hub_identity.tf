# The hub's own identity. No management-plane role, so it cannot fetch the account key, edit the
# lifecycle policy or switch off versioning; Storage Blob Data Contributor cannot delete a previous
# version either. The secret goes root-only onto the hub, not into Key Vault: nothing in a cluster
# consumes it.

data "azuread_client_config" "current" {}

locals {
  # The same date as production's backup identities, so one renewal covers all three.
  hub_secret_end_date = "2028-08-01T00:00:00Z"
}

resource "azuread_application" "hub" {
  display_name = "sp-homelab-personal-data-hub"
  owners       = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "hub" {
  client_id = azuread_application.hub.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_password" "hub" {
  application_id = azuread_application.hub.id
  display_name   = "personal-data hub credential"
  end_date       = local.hub_secret_end_date

  # A renewal mints the new secret before the old one is revoked.
  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_role_assignment" "hub_container" {
  scope                = module.storage.container_ids["restic"]
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.hub.object_id
}

# The operator's own access, for listing versions and soft-deleted blobs, and for a restore that does
# not need the hub.
resource "azurerm_role_assignment" "operator_blob_data" {
  scope                = module.storage.container_ids["restic"]
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azuread_client_config.current.object_id
}

output "hub_client_id" {
  value = azuread_application.hub.client_id
}

output "tenant_id" {
  value = data.azuread_client_config.current.tenant_id
}

output "hub_client_secret" {
  value     = azuread_application_password.hub.value
  sensitive = true
}
