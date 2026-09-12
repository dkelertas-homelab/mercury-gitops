# Secrets bootstrap sketch (customer1)

## Problem

`apps/base/customer1/secrets.yaml` defines a `SecretProviderClass` with `secretObjects`
that *would* create:

- `customer1-db-credentials` (basic-auth for CNPG `initdb`)
- `customer1-n8n-env`
- `customer1-backup-creds`

Azure Key Vault CSI only writes those Kubernetes Secrets **when a pod successfully
mounts** the CSI volume. Today the only mounter is the n8n Deployment, while the
CNPG `Cluster` needs `customer1-db-credentials` **before** initdb starts.

That is a chicken-and-egg, not a Flux HelmRelease `dependsOn` between controllers.

Separately, the staging SPC patch must use the **current** AKS addon identity
(`azureKeyvaultSecretsProvider` / terraform output `aks_keyvault_secrets_provider_client_id`).
A stale `userAssignedIdentityID` fails the mount with `Identity not found`.

## Option A — External Secrets Operator (preferred long-term)

ESO syncs KV → Secret continuously **without** needing a consumer pod first.

Sketch files (not applied by Flux yet):

- `eso-helmrelease.sketch.yaml` — controller under `infra-controllers`
- `secretstore.sketch.yaml` — Azure KV store (Workload Identity / UAMI)
- `externalsecrets.sketch.yaml` — the three customer1 Secrets

Ordering once enabled:

1. Install ESO HelmRelease (depends on nothing special; cert-manager optional).
2. Apply `SecretStore` / `ClusterSecretStore` + `ExternalSecret`s in a **secrets**
   Kustomization (or app path) that becomes Ready when Secrets exist.
3. Make the apps Kustomization `dependsOn` that secrets layer (or split
   `customer1` into secrets → database → app with Flux KS `dependsOn`).

Migration: keep CSI for optional file mounts, or drop `secretObjects` + n8n CSI
volume once ExternalSecrets own the three Secrets.

## Option B — Sync Job (lighter stopgap, keeps CSI)

Sketch: `sync-job.sketch.yaml`

A one-shot Job mounts `SecretProviderClass` `customer1-secrets`, waits until
`customer1-db-credentials` exists, then exits. Force secretObjects sync **before**
CNPG / n8n need the Secrets.

Ordering:

- Apply SPC + Job first (secrets-sync KS), healthCheck the Job / Secret.
- Apps KS `dependsOn` secrets-sync KS.
- Or temporarily suspend / delay Cluster until Secret exists.

Still requires a correct `userAssignedIdentityID` on the SPC.

## What we changed for real in this PR

- Barman HelmRelease `dependsOn: [cert-manager, cnpg]` (+ install/upgrade retries).
- Staging SPC identity patch → live addon client id.

These sketch YAMLs are **not** listed in any `kustomization.yaml` — opt-in later.
