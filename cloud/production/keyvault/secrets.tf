resource "time_rotating" "secret_rotation" {
  rotation_days = 60
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

  # NOTE: workaround, we need to wait for the role assignment to be ready
  depends_on = [module.keyvault]
}
