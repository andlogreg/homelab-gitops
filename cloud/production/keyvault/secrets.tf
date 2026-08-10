resource "time_rotating" "secret_rotation" {
  rotation_days = 60
}

#### Mealie Secrets ####
resource "random_password" "mealie_db_credentials_password" {
  length  = 40
  special = true

  # This password is interpolated into a PostgreSQL connection URI
  # (postgresql://mealie:<password>@<host>:5432/mealie) by the ExternalSecret
  # template, with no percent-encoding. Two characters from the provider's
  # default special set break that URI, and neither breaks it loudly:
  #   @  ends the userinfo component early, so the driver reads the rest of the
  #      password as the hostname and cannot resolve it.
  #   %  is read as the start of a percent-escape, so the driver silently
  #      authenticates with a different password than the one in Key Vault.
  # At length 40 a default-alphabet password contains an @ roughly 38% of the
  # time, so most rotations were a coin flip - and because nothing re-reads the
  # credential until the pod restarts, the breakage surfaced far from its cause.
  # Every other default special character was verified to round-trip correctly.
  override_special = "!#$&*()-_=+[]{}<>:?"

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

#### Health Secrets ####
resource "random_password" "health_db_credentials_password" {
  length  = 40
  special = true

  # Same alphabet, same reason as mealie above: this value is interpolated into a
  # PostgreSQL connection URI by the ExternalSecret template with no percent-encoding,
  # so `@` and `%` both break it and neither breaks it loudly.
  override_special = "!#$&*()-_=+[]{}<>:?"

  keepers = {
    rotation_time = time_rotating.secret_rotation.id
  }
}

resource "azurerm_key_vault_secret" "health_db_credentials_password" {
  name         = "health-db-credentials-password"
  value        = random_password.health_db_credentials_password.result
  key_vault_id = module.keyvault.id

  # NOTE: workaround, we need to wait for the role assignment to be ready
  depends_on = [module.keyvault]
}

# Grafana never receives the write-capable health application credential. This
# password belongs to a separate LOGIN role whose only membership is the
# NOLOGIN health_read group. It rotates on the same schedule as the database
# application credentials; External Secrets delivers it to both namespaces and
# Reloader restarts Grafana after the monitoring copy changes.
resource "random_password" "health_db_grafana_password" {
  length  = 40
  special = true

  # The password is injected directly into Grafana's datasource provisioning
  # through an environment variable. Keep the estate's URI-safe alphabet so a
  # future consumer cannot silently misparse the same value in a connection URI.
  override_special = "!#$&*()-_=+[]{}<>:?"

  keepers = {
    rotation_time = time_rotating.secret_rotation.id
  }
}

resource "azurerm_key_vault_secret" "health_db_grafana_password" {
  name         = "health-db-grafana-password"
  value        = random_password.health_db_grafana_password.result
  key_vault_id = module.keyvault.id

  # NOTE: workaround, we need to wait for the role assignment to be ready
  depends_on = [module.keyvault]
}
