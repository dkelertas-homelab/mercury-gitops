#!/usr/bin/env bash
# Ask Flux to reconcile now and don't wait for the next sync interval (5m).
# In GitOps the merge *is* the deploy. This only shortens the wait between
# the merge and Flux pulling it.
#
# Uses the same annotation `flux reconcile` sets, so it works with plain
# kubectl (e.g. inside `az aks command invoke`) as well as with the flux CLI installed.
#
#   scripts/flux-reconcile.sh             # all GitRepositories + Kustomizations in flux-system
set -euo pipefail

NS="${FLUX_NAMESPACE:-flux-system}"
now="$(date +%s)"

if command -v flux >/dev/null 2>&1; then
  for repo in $(kubectl get gitrepositories.source.toolkit.fluxcd.io -n "$NS" -o name | cut -d/ -f2); do
    flux reconcile source git "$repo" -n "$NS" --timeout=3m
  done
else
  kubectl annotate --overwrite -n "$NS" gitrepositories.source.toolkit.fluxcd.io --all \
    "reconcile.fluxcd.io/requestedAt=${now}"
  kubectl wait --for=condition=Ready -n "$NS" gitrepositories.source.toolkit.fluxcd.io --all --timeout=3m
fi

# Kustomizations depend on each other (infra-controllers -> infra-configs -> apps ...),
# so nudge them all and let Flux's dependsOn handle the order. health-check.sh waits for Ready.
kubectl annotate --overwrite -n "$NS" kustomizations.kustomize.toolkit.fluxcd.io --all \
  "reconcile.fluxcd.io/requestedAt=${now}"

kubectl get gitrepositories.source.toolkit.fluxcd.io,kustomizations.kustomize.toolkit.fluxcd.io -n "$NS"
