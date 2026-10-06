#!/usr/bin/env bash
# List the Flux entrypoints in this repo: the overlay dirs that Flux
# Kustomizations point at (./apps/<env>, ./infrastructure/*/<env>,
# ./monitoring/*/<env>).
#
# Env mapping (GitHub Environment <- overlay dir name):
#   dev  <- staging     (cluster mercury-staging)
#   prod <- production  (cluster mercury-production, when it exists)
#
# Usage:
#   scripts/list-overlays.sh          # "<env> <path>" per line
#   scripts/list-overlays.sh --json   # [{"env":"dev","path":"apps/staging"}, ...]
#   scripts/list-overlays.sh --envs   # ["dev", ...] (distinct envs)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

list() {
  find apps infrastructure monitoring -type d \( -name staging -o -name production \) 2>/dev/null |
    sort |
    while read -r dir; do
      [[ -f "$dir/kustomization.yaml" ]] || continue
      case "$(basename "$dir")" in
        staging) env=dev ;;
        production) env=prod ;;
      esac
      echo "$env $dir"
    done
}

case "${1:-}" in
  --json) list | jq -R -s -c 'split("\n") | map(select(length > 0) | split(" ") | {env: .[0], path: .[1]})' ;;
  --envs) list | jq -R -s -c 'split("\n") | map(select(length > 0) | split(" ")[0]) | unique' ;;
  "") list ;;
  *) echo "usage: $0 [--json|--envs]" >&2; exit 2 ;;
esac
