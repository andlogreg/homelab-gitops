output "id" {
  description = "Key Vault ID."
  value       = azurerm_key_vault.key_vault.id
}

output "name" {
  description = "Key Vault name."
  value       = azurerm_key_vault.key_vault.name
}

output "vault_uri" {
  description = "Key Vault URI."
  value       = azurerm_key_vault.key_vault.vault_uri
}
