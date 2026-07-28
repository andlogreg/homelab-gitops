# Workload Identity Federation for External Secrets Operator (ESO) — lets ESO authenticate
# to Key Vault with no stored client secret.
#
# The public container contains only the discovery document and JWKS for k3s's existing
# ServiceAccount signing key. Azure AD reads those public keys to validate the token
# minted for external-secrets/eso-azure-wi.

locals {
  # primary_blob_endpoint already ends in "/". Discovery lives at
  # <issuer>/.well-known/openid-configuration; JWKS at <issuer>/openid/v1/jwks.
  oidc_issuer_url = "${azurerm_storage_account.oidc.primary_blob_endpoint}${azurerm_storage_container.oidc.name}"
}

resource "azurerm_storage_account" "oidc" {
  name                     = var.oidc_storage_account_name
  resource_group_name      = "rg-homelab-helios"
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = true # required for anonymous discovery/JWKS reads

  tags = var.tags
}

resource "azurerm_storage_container" "oidc" {
  name                  = "oidc"
  storage_account_id    = azurerm_storage_account.oidc.id
  container_access_type = "blob" # anonymous read of individual blobs, no listing
}

# Lets the Terraform-applying identity publish the public discovery document and JWKS
# with scripts/publish-oidc-jwks.sh using Entra authentication.
resource "azurerm_role_assignment" "oidc_publisher" {
  scope                = azurerm_storage_account.oidc.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azuread_client_config.current.object_id
}

resource "azuread_application_federated_identity_credential" "eso" {
  application_id = azuread_application.eso.id
  display_name   = "eso-k3s-workload-identity"
  description    = "Trusts ESO's projected ServiceAccount token from helios's k3s OIDC issuer."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = local.oidc_issuer_url
  subject        = "system:serviceaccount:external-secrets:eso-azure-wi"
}

output "oidc_issuer_url" {
  description = "Set as k3s --service-account-issuer and used by the JWKS publish helper."
  value       = local.oidc_issuer_url
}
