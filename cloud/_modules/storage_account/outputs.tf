output "id" {
  description = "Storage Account ID."
  value       = azurerm_storage_account.storage.id
}

output "name" {
  description = "Storage Account name."
  value       = azurerm_storage_account.storage.name
}

output "primary_blob_endpoint" {
  description = "Storage Account blob endpoint."
  value       = azurerm_storage_account.storage.primary_blob_endpoint
}

output "primary_access_key" {
  description = "The primary access key for the storage account."
  value       = azurerm_storage_account.storage.primary_access_key
  sensitive   = true
}
