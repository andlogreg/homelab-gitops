resource "time_rotating" "secret_rotation" {
  # NOTE: 5 minutes only for testing purposes
  rotation_minutes = 5
}

#### Mealie Secrets ####
resource "random_password" "mealie_db_credentials_password" {
  length  = 40
  special = true
  keepers = {
    rotation_time = time_rotating.secret_rotation.id
  }
}

resource "azurerm_key_vault_secret" "mealie_db_credentials_password" {
  name         = "mealie-db-credentials-password"
  value        = random_password.mealie_db_credentials_password.result
  key_vault_id = module.keyvault.id
}
