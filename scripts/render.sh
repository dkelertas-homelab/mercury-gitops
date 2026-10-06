#!/usr/bin/env bash
# "Build" stage for a GitOps repo: render every overlay for one environment
# into plain manifests, plus an index of what's in them (container images,
# Helm charts, ingress hosts). CI publishes the result as a workflow artifact.
#
#   scripts/render.sh dev        # -> rendered/dev/*.yaml + rendered/dev/index.md
#
# Needs: kustomize, yq (mikefarah v4)
set -euo pipefail

env_name="${1:?usage: $0 <env>   (dev|prod)}"

cd "$(git rev-parse --show-toplevel)"
outdir="rendered/${env_name}"
rm -rf "$outdir"
mkdir -p "$outdir"

mapfile -t overlays < <(scripts/list-overlays.sh | awk -v e="$env_name" '$1 == e { print $2 }')
if [[ ${#overlays[@]} -eq 0 ]]; then
  echo "no overlays for env '${env_name}'" >&2
  exit 1
fi

index="${outdir}/index.md"
{
  echo "# Rendered manifests: ${env_name}"
  echo
  echo "- commit: \`$(git rev-parse HEAD)\`"
  echo "- rendered: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "| Overlay | Resources |"
  echo "|---|---|"
} > "$index"

for overlay in "${overlays[@]}"; do
  out="${outdir}/${overlay//\//_}.yaml"
  kustomize build "$overlay" > "$out"
  echo "| \`${overlay}\` | $(yq ea '[.] | length' "$out") |" >> "$index"
done

all=("${outdir}"/*.yaml)
{
  echo
  echo "## Container images"
  echo
  # shellcheck disable=SC2016  # backticks are Markdown, not command substitution
  yq e '.. | select(tag == "!!map" and has("image")) | .image' "${all[@]}" | sort -u | sed 's/^/- `/; s/$/`/'
  echo
  echo "## Helm charts"
  echo
  echo "| HelmRelease | Chart | Version |"
  echo "|---|---|---|"
  yq e 'select(.kind == "HelmRelease") | "| " + .metadata.name + " | " + .spec.chart.spec.chart + " | " + .spec.chart.spec.version + " |"' "${all[@]}" | sort
  echo
  echo "## Ingress hosts"
  echo
  {
    # plain Ingress objects
    yq e 'select(.kind == "Ingress") | .spec.rules[].host' "${all[@]}"
    # ingresses created by Helm charts from values.yaml ConfigMaps (e.g. Grafana)
    yq e 'select(.kind == "ConfigMap" and has("data") and .data | has("values.yaml")) | .data["values.yaml"] | from_yaml | .. | select(tag == "!!map" and has("ingress")) | .ingress.hosts[]' "${all[@]}"
  } | { grep -v '^---$' || true; } | sort -u | sed 's/^/- /'
} >> "$index"

echo "Rendered ${#overlays[@]} overlays for ${env_name} into ${outdir}"
