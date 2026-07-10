# AGENTS.md — homelab-gitops

Short guidance for AI agents (and humans) working in this repo. The [README](README.md) is the
canonical overview; this file is just the rules that are easy to get wrong.

## What this is
GitOps for a hybrid homelab: **Flux** reconciles Kubernetes manifests across four clusters
(`dev-local`, `phoenix_staging`, `phoenix_production`, `helios`); **Terraform** (`cloud/`) manages
the Azure layer (remote state in Azure Blob, secrets in Azure Key Vault).

## Golden rules
- **Never commit a plaintext secret — this repo is public.** Everything committed is encrypted with
  **SOPS/age** (`.sops.yaml`); runtime secrets are pulled from **Azure Key Vault via External
  Secrets Operator**. `detect-secrets` and the pre-commit hooks enforce this — don't bypass them.
- **Flux owns the clusters.** Express changes as manifests here and let Flux reconcile; don't apply
  ad-hoc changes to a cluster or hand-edit Flux-generated files.
- **Keep environments isolated** — no shared state; scope changes to the right overlay/cluster.

## Working here
- Tooling is pinned with **mise** (`mise install`). Terraform: `az login`, then
  `terraform init -backend-config=backend.hcl`.
- **Conventional Commits** are enforced (commitizen); all pre-commit hooks must pass.
- **Push directly to `main`** — no pull-request workflow for this repo.

## Context
Design rationale and the broader homelab architecture live in a separate (private) knowledge base;
this repo is the implementation, and it doubles as a public reference — keep it tidy.
