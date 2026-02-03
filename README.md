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
-   **State Management**: Terraform statefiles are securely stored in Azure Blob Storage.
-   **Key Vaults**: Azure Key Vault is used for reliable secret storage and backups.
-   **Structure**:
    -   `cloud/_modules/`: Reusable Terraform modules.
    -   `cloud/<env>/`: Isolated environment configurations.

## 🚀 Deployed Applications
The stack changes over time as I experiment with new tools and services. Currently, it includes a suite of self-hosted applications, such as:

-   **AI & LLM**: `vllm`, `ollama`, `open-webui`, `litellm`, `mealie-rag`
-   **Home & Utility**: `home-automation`, `homarr` (dashboard), `mealie` (recipes), `audiobookshelf`, `dashy`
-   **Infrastructure**: `linkding`, `littlelink`, `n8n` (workflow automation), `pgadmin`, `cloudflared`

## 🛠 Tech Stack

| Category | Technologies |
|----------|--------------|
| **Core Platform** | **Kubernetes** (Flux CD), **Terraform** (IaC), **Microsoft Azure** (Hybrid Cloud) |
| **Observability** | **Prometheus** (Metrics), **Grafana** (Visualisation), **Loki** (Logs), **Alertmanager** |
| **Storage & DB** | **CloudNativePG** (PostgreSQL HA) |
| **Security** | **External Secrets Operator** (Azure Key Vault Integration), **SOPS/age** (Git Encryption), **Cert-Manager** (TLS), **Cloudflare Tunnel** (Zero Trust) |
| **AI & Edge** | **NVIDIA GPU Operator** (Hardware Acceleration), **vLLM**, **Ollama** |
| **Automation** | **Renovate** (Dependency Updates), **GitHub Actions** (CI/CD) |

---

## 🔐 Secrets Management

### 1. Git Encryption (At Rest)
-   **Tooling**: **Mozilla SOPS** + **age**.
-   **Strategy**: All secrets committed to Git are encrypted.
-   **Trust**: The repo is untrusted (public); the secret keys never leave the developer's local machine or the cluster.

### 2. Runtime Injection (Production)
-   **Tooling**: **External Secrets Operator (ESO)** + **Azure Key Vault**.
-   **Strategy**: Production-grade secrets (API keys, database credentials) are stored in **Azure Key Vault**. ESO securely syncs them into Kubernetes `Secrets` at runtime via `ClusterSecretStore`.
-   **Benefit**: Centralized audit logging, rotation, and access control on Azure.

### Workflow for New Secrets (Git-based)
1.  Create a plain secret (NEVER COMMIT THIS):
    ```yaml
    apiVersion: v1
    kind: Secret
    metadata:
        name: my-secret
    stringData:
        token: super-secret-value
    ```
2.  Encrypt it: `sops encrypt -i secret.yaml`
3.  Commit the encrypted file.

### Key Rotation
1.  Generate new age key pair.
2.  Update `.sops.yaml`.
3.  Re-encrypt: `sops updatekeys -y -r secret.yaml`.

## ⚡ Developer Workflow

### Pre-commit Hooks
Verify everything before it hits the remote:
-   Prevent plaintext secret commits (`detect-secrets`, etc).
-   Enforce commit message styles.
-   Lint and format YAML/Terraform.

### Azure & Terraform
```bash
# Login
az login --use-device-code

# Terraform Init
terraform init -backend-config=backend.hcl
```
