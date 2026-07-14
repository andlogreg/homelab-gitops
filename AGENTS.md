# AGENTS.md — homelab-gitops

Short guidance for AI agents (and humans) working in this repo. The [README](README.md) is the
canonical overview; this file is just the rules that are easy to get wrong.

## What this is
GitOps for a hybrid homelab: **Flux** reconciles Kubernetes manifests across four clusters
(`dev-local`, `phoenix_staging`, `phoenix_production`, `helios`); **Terraform** (`cloud/`) manages
the Azure layer (remote state in Azure Blob, secrets in Azure Key Vault).

## Golden rules
- **Never commit secret material — this repo is public.** No secret payload, plaintext *or*
  encrypted, belongs in git: secrets live in **Azure Key Vault** and are pulled in at runtime via
  **External Secrets Operator** (`ExternalSecret` references only). `gitleaks` plus the local
  `no-committed-secret-payload` guard (fails on any `kind: Secret` with a populated `data`/`stringData`)
  enforce this — don't bypass them. (SOPS/age-in-git was retired.)
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
