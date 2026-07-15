# Workload Identity Federation for External Secrets Operator (ESO) — lets ESO authenticate
# to Key Vault with no stored client secret.
#
# Two pieces live here:
#   1. A small public storage account hosting the cluster's OIDC discovery document + JWKS.
#      Only PUBLIC keys are published — never anything secret. Azure AD fetches these read-only
#      to validate the cluster's ServiceAccount tokens; it never connects into the cluster.
#   2. A federated identity credential on the ESO app registration, trusting the projected
#      ServiceAccount token minted by the cluster's OIDC issuer.
#
# The k3s API server sets --service-account-issuer to oidc_issuer_url (below), and the OIDC
# discovery doc + JWKS are published into the "oidc" container. The ESO ServiceAccount
# (external-secrets/eso-azure-wi) then presents its token and Azure returns a Key Vault token.

locals {
  # Issuer = the public blob container root. primary_blob_endpoint already ends in "/".
  # Discovery doc is served at <issuer>/.well-known/openid-configuration; JWKS at <issuer>/openid/v1/jwks.
  oidc_issuer_url = "${azurerm_storage_account.oidc.primary_blob_endpoint}${azurerm_storage_container.oidc.name}"
}

resource "azurerm_storage_account" "oidc" {
  name                     = var.oidc_storage_account_name
  resource_group_name      = "rg-homelab-production"
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = true # required for anonymous read of the public JWKS/discovery blobs

  tags = var.tags
}

resource "azurerm_storage_container" "oidc" {
  name                  = "oidc"
  storage_account_id    = azurerm_storage_account.oidc.id
  container_access_type = "blob" # anonymous read of individual blobs (no container listing)
}

// Lets whoever runs `terraform apply` also publish the discovery doc + JWKS blobs
// (scripts/publish-oidc-jwks.sh uploads with --auth-mode login).
resource "azurerm_role_assignment" "oidc_publisher" {
  scope                = azurerm_storage_account.oidc.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azuread_client_config.current.object_id
}

resource "azuread_application_federated_identity_credential" "eso" {
  application_id = azuread_application.eso.id
  display_name   = "eso-k3s-workload-identity"
  description    = "Trusts ESO's projected SA token from the k3s cluster OIDC issuer (WIF)."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = local.oidc_issuer_url
  subject        = "system:serviceaccount:external-secrets:eso-azure-wi"
}

output "oidc_issuer_url" {
  description = "Set as k3s --service-account-issuer and used by the JWKS publish helper."
  value       = local.oidc_issuer_url
}
