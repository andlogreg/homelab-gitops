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

# Container ARM IDs, keyed by container name. These are role-assignment scopes: granting a data
# role HERE rather than on the account is what keeps a backup credential inside its own container.
# The resource `id` is already the ARM ID (.../blobServices/default/containers/<name>) because the
# containers are declared with `storage_account_id`, the Resource Manager form.
output "container_ids" {
  description = "Map of container name -> ARM resource ID, for container-scoped role assignments."
  value       = { for name, container in azurerm_storage_container.containers : name => container.id }
}
