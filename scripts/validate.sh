#!/usr/bin/env bash
# Render each Flux overlay with kustomize and validate the output with
# kubeconform (core schemas + the datreeio CRD catalog for Flux, CNPG,
# cert-manager, Cilium, Secrets Store CSI...).
#
# Same logic CI runs per matrix leg, so it works locally too:
#   scripts/validate.sh                      # all overlays
#   scripts/validate.sh apps/staging         # one overlay
#
# Needs: kustomize, kubeconform (versions pinned in .github/workflows/validate.yml)
# Writes: rendered/<overlay_path_with_underscores>.yaml (git-ignored)
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-1.34.0}"
CRD_CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

cd "$(git rev-parse --show-toplevel)"
mkdir -p rendered

if [[ $# -gt 0 ]]; then
  overlays=("$@")
else
  mapfile -t overlays < <(scripts/list-overlays.sh | cut -d' ' -f2)
fi

rc=0
for overlay in "${overlays[@]}"; do
  out="rendered/${overlay//\//_}.yaml"
  echo "::group::${overlay}"
  if ! kustomize build "$overlay" > "$out"; then
    echo "::error::kustomize build failed for ${overlay}"
    rc=1; echo "::endgroup::"; continue
  fi
  if ! kubeconform \
      -strict \
      -summary \
      -ignore-missing-schemas \
      -kubernetes-version "$K8S_VERSION" \
      -schema-location default \
      -schema-location "$CRD_CATALOG" \
      ${KUBECONFORM_CACHE:+-cache "$KUBECONFORM_CACHE"} \
      "$out"; then
    echo "::error::kubeconform found invalid resources in ${overlay}"
    rc=1
  fi
  echo "::endgroup::"
done
exit "$rc"
