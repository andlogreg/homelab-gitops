# Homelab GitOps

A **GitOps** repository managing my hybrid homelab infrastructure. I'm aiming for a reliable, secure, and automated infrastructure management using **Kubernetes (Flux)** and **Terraform** on **Azure**.

## 🏗 Infrastructure Architecture

Hybrid architecture combining local bare-metal performance with cloud-managed state and security.

### Clusters
The infrastructure manages multiple Kubernetes clusters, each serving a distinct purpose:
-   **`dev-local`**: Local development environment for quickly testing things out.
-   **`phoenix_staging`**: Staging environment for testing deployments before production.
-   **`phoenix_production`**: Production environment hosting stable services.
-   **`helios`**: Specialized environment (e.g., GPU/AI workloads).

### Hybrid Cloud (Azure)
Resources are provisioned via Terraform in the `cloud/` directory.
-   **State Management**: Terraform statefiles are securely stored in Azure Blob Storage — accessed with **Microsoft Entra ID** (`use_azuread_auth`), never a storage-account key, on an account with blob versioning + soft delete for recovery.
-   **Key Vaults**: Azure Key Vault is used for reliable secret storage and backups.
-   **Structure**:
    -   `cloud/_modules/`: Reusable Terraform modules.
    -   `cloud/<env>/`: Isolated environment configurations.

## 🚀 Deployed Applications
The stack changes over time as I experiment with new tools and services. Currently, it includes a suite of self-hosted applications, such as:

-   **AI & LLM**: `vllm`, `ollama`, `open-webui`, `litellm`, `mealie-rag`
-   **Home & Utility**: `homarr` (dashboard), `mealie` (recipes), `audiobookshelf`, `dashy`
-   **Infrastructure**: `linkding`, `littlelink`, `n8n` (workflow automation), `pgadmin`, `cloudflared`

## 🛠 Tech Stack

| Category | Technologies |
|----------|--------------|
| **Core Platform** | **Kubernetes** (Flux CD), **Terraform** (IaC), **Microsoft Azure** (Hybrid Cloud) |
| **Observability** | **Prometheus** (Metrics), **Grafana** (Visualisation), **Loki** (Logs), **Alertmanager** |
| **Storage & DB** | **CloudNativePG** (PostgreSQL HA) |
| **Security** | **External Secrets Operator** (Azure Key Vault Integration), **Cert-Manager** (TLS), **Cloudflare Tunnel** (Zero Trust) |
| **AI & Edge** | **NVIDIA GPU Operator** (Hardware Acceleration), **vLLM**, **Ollama** |
| **Automation** | **Renovate** (Dependency Updates), **GitHub Actions** (CI/CD) |

---

## 🔐 Secrets Management

**One model: no secret material in git.** All secrets — plaintext *or* encrypted — stay out of this
(public) repo. Git holds only `ExternalSecret` *references*; the values live in **Azure Key Vault**
and are pulled into the cluster at runtime by the **External Secrets Operator (ESO)**.

-   **Store**: **Azure Key Vault** (one per cluster) is the source of truth for every secret.
-   **Sync**: ESO's `ClusterSecretStore` authenticates to Key Vault via **Workload Identity
    Federation** — the cluster's ServiceAccount token is exchanged for a short-lived Key Vault token,
    so **no client secret is stored in the cluster**. Each `ExternalSecret` materialises a Kubernetes
    `Secret` at runtime.
-   **Benefit**: centralized audit logging, rotation, and access control on Azure — nothing to
    decrypt, no encryption key in git, and no long-lived cloud credential to rotate.

> Historical note: this repo previously committed **SOPS/age**-encrypted secrets. That was retired —
> even encrypted secrets are unwanted blast radius in a public repo.

### Workflow for a new secret
1.  Put the value in Azure Key Vault (kebab-case name):
    ```bash
    az keyvault secret set --vault-name <kv-...> --name my-app-token --value "<value>"
    ```
2.  Add an `ExternalSecret` that references it (mirror an existing one, e.g. `apps/base/homarr/external-secret.yaml`):
    ```yaml
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: my-app
    spec:
      refreshInterval: 3h
      secretStoreRef:
        kind: ClusterSecretStore
        name: cluster-secret-store
      target:
        name: my-app
      data:
      - secretKey: MY_APP_TOKEN
        remoteRef:
          key: my-app-token
    ```
3.  Wire it into the relevant `kustomization.yaml` and commit. **Never commit a `kind: Secret` with a
    payload** — the pre-commit guard blocks it.

### Rotation
Rotate the value in Azure Key Vault; ESO re-syncs it into the cluster within `refreshInterval`. No git
change and no encryption-key rotation required.

## ⚡ Developer Workflow

### Pre-commit Hooks
Verify everything before it hits the remote:
-   Scan for leaked credentials (`gitleaks`) and block any committed `kind: Secret` that carries a
    payload (local `no-committed-secret-payload` guard).
-   Enforce commit message styles.
-   Lint and format YAML/Terraform.

### Azure & Terraform
```bash
# Login — this is also how Terraform authenticates to the state backend
az login --use-device-code

# The azurerm provider (v4+) will not infer the subscription from the CLI — set it explicitly
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Terraform Init (from a root module, e.g. cloud/production/keyvault)
terraform init -backend-config=../../backend.hcl
```

State access uses **Entra ID** (`use_azuread_auth = true` in each root module's backend block),
so there is no storage-account key anywhere. Two consequences worth knowing:

-   Your identity needs the **Storage Blob Data Contributor** role on the state container.
    Subscription *Owner* is management-plane only and is **not** enough — `init` will fail on a
    blob-list authorization error. Shared-key access is disabled on the account, so there is no
    key fallback.
-   `az storage` commands against that account need `--auth-mode login`. The CLI defaults to key
    auth regardless of the account's `defaultToOAuthAuthentication` setting, and key auth is now
    refused (`KeyBasedAuthenticationNotPermitted`). `export AZURE_STORAGE_AUTH_MODE=login` once per
    shell if you'd rather not repeat the flag.

**Recovering a clobbered state file.** The state account has blob versioning + soft delete, so a
bad `apply`, `state rm`, or deletion is recoverable. Note that `az storage blob undelete` is *not*
the path (with versioning on, a deleted blob simply becomes a previous version) — list versions and
promote one:

```bash
ACCT=<state-account>; CT=<state-container>; KEY=homelab/cloud/<env>/<module>/terraform.tfstate

# 1. find the good version (newest first; the drift you want to undo is the current one)
az storage blob list --account-name $ACCT -c $CT --prefix $KEY --include v --auth-mode login \
  --query "[].{versionId:versionId, isCurrent:isCurrentVersion, modified:properties.lastModified}" -o table

# 2. pull it down and 3. re-upload it as the current version
az storage blob download --account-name $ACCT -c $CT -n $KEY --version-id <VERSION_ID> \
  --file recovered.tfstate --auth-mode login
az storage blob upload --account-name $ACCT -c $CT -n $KEY --file recovered.tfstate \
  --overwrite --auth-mode login
```
