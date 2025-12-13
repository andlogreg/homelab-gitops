## Secrets Management

This setup assumes git repo may be public but the cluster is trusted.

Secrets are **not** stored in plaintext.

Secrets are encrypted using:
- **SOPS (Mozilla)**
- **age encryption**

Only encrypted Kubernetes manifests are committed to Git.  
Decryption happens at deploy time inside the cluster via Flux.

Plaintext secrets never leave the local machine.

### Encrypting new secret

1. Start with plain secret (Never to be commited)
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
      name: my-secret
   type: Opaque
   stringData:
      token: super-secret-value
   ```
2. Encrypt it in place `sops encrypt -i secret.yaml`
3. Verify with `sops secret.yaml`


### Pre-commit

Pre-commit hooks are used locally to prevent accidental
plaintext secret commits.

### Key Rotation

1. Generate a new age key pair
2. Update `.sops.yaml` with the new public key
3. Re-encrypt existing secrets:
   ```bash
   sops updatekeys -y secret.yaml
   ```
4. Update the age private key stored in the flux-system namespace
5. Commit the re-encrypted manifests
