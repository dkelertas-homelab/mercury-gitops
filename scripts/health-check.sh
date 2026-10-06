#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329  # helpers are invoked indirectly via check()
# Post-deploy health checks for a Mercury cluster. Runs the same in CI
# (.github/workflows/verify.yml) and locally against the current kubectl context:
#
#   az aks get-credentials -g rg-cloud-course-aks -n mercury-staging
#   kubelogin convert-kubeconfig -l azurecli
#   scripts/health-check.sh            # cluster + endpoints
#   scripts/health-check.sh cluster    # Flux / HelmReleases / Deployments / CNPG only
#   scripts/health-check.sh endpoints  # HTTPS + TLS only (no kubectl needed if HOSTS is set)
#
# Env overrides:
#   TIMEOUT        kubectl wait timeout per check            (default 5m)
#   NAMESPACES     namespaces whose Deployments/CNPG to check (default: infra namespaces + apps/base/*)
#   HOSTS          space-separated hostnames to smoke test     (default: every Ingress host in the cluster)
#   CERT_MIN_DAYS  fail if a TLS cert expires sooner than this (default 14)
#   EXPECTED_REVISION  commit SHA Flux should have pulled; mismatch is a warning, not a failure
#
# Needs: kubectl (cluster mode), curl + openssl (endpoints mode). flux CLI optional.
set -uo pipefail

MODE="${1:-all}"
TIMEOUT="${TIMEOUT:-5m}"
CERT_MIN_DAYS="${CERT_MIN_DAYS:-14}"
FLUX_NS="flux-system"

results=()   # "PASS|FAIL|WARN<TAB>check<TAB>detail"
failed=0

record() { # record <PASS|FAIL|WARN> <check> [detail]
  results+=("$1"$'\t'"$2"$'\t'"${3:-}")
  case "$1" in
    PASS) echo "✅ $2 ${3:-}" ;;
    WARN) echo "::warning::$2 ${3:-}" ;;
    FAIL) echo "::error::$2 ${3:-}"; failed=1 ;;
  esac
}

# check <name> <command...>: run a command, record PASS/FAIL from its exit code
check() {
  local name=$1; shift
  echo "::group::${name}"
  if "$@"; then echo "::endgroup::"; record PASS "$name"
  else echo "::endgroup::"; record FAIL "$name"; fi
}

default_namespaces() {
  local ns="traefik cert-manager cnpg-system monitoring"
  local root
  if root=$(git rev-parse --show-toplevel 2>/dev/null) && [[ -d "$root/apps/base" ]]; then
    for d in "$root"/apps/base/*/; do ns+=" $(basename "$d")"; done
  fi
  echo "$ns"
}

# kubectl wait on every object of <kind> in <namespace>, if any exist
wait_kind() { # wait_kind <kind> <namespace> <condition>
  local kind=$1 ns=$2 cond=$3
  if [[ -z "$(kubectl get "$kind" -n "$ns" -o name 2>/dev/null)" ]]; then
    echo "no ${kind} in ${ns}"; return 0
  fi
  kubectl get "$kind" -n "$ns"
  kubectl wait --for="condition=${cond}" "$kind" --all -n "$ns" --timeout="$TIMEOUT"
}

namespaces_of() { # namespaces_of <kind>
  kubectl get "$1" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u
}

cluster_checks() {
  echo "Context: $(kubectl config current-context 2>/dev/null || echo '?')"
  if ! kubectl version >/dev/null 2>&1; then
    record FAIL "kubectl can reach the API server"; return
  fi

  # 1. Flux sources + Kustomizations (the AKS Flux extension puts them in flux-system)
  check "Flux GitRepositories Ready" wait_kind gitrepositories.source.toolkit.fluxcd.io "$FLUX_NS" Ready
  check "Flux Kustomizations Ready" wait_kind kustomizations.kustomize.toolkit.fluxcd.io "$FLUX_NS" Ready

  if [[ -n "${EXPECTED_REVISION:-}" ]]; then
    local revs
    revs=$(kubectl get gitrepositories.source.toolkit.fluxcd.io -n "$FLUX_NS" -o jsonpath='{range .items[*]}{.status.artifact.revision}{"\n"}{end}')
    if grep -q "$EXPECTED_REVISION" <<< "$revs"; then
      record PASS "Flux pulled expected commit" "${EXPECTED_REVISION:0:7}"
    else
      record WARN "Flux revision differs from this commit" "want ${EXPECTED_REVISION:0:7}, cluster has: $(tr '\n' ' ' <<< "$revs")"
    fi
  fi

  # 2. HelmReleases in every namespace that has them
  local ns
  for ns in $(namespaces_of helmreleases.helm.toolkit.fluxcd.io); do
    check "HelmReleases Ready (${ns})" wait_kind helmreleases.helm.toolkit.fluxcd.io "$ns" Ready
  done

  # 3. Deployments available + CNPG clusters healthy
  for ns in ${NAMESPACES:-$(default_namespaces)}; do
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
      record FAIL "Namespace exists (${ns})"; continue
    fi
    check "Deployments Available (${ns})" wait_kind deployments "$ns" Available
  done
  for ns in $(namespaces_of clusters.postgresql.cnpg.io); do
    check "CNPG clusters Ready (${ns})" wait_kind clusters.postgresql.cnpg.io "$ns" Ready
  done

  if command -v flux >/dev/null 2>&1; then
    echo "::group::flux get all (summary)"
    flux get sources git -A; flux get kustomizations -A; flux get helmreleases -A
    echo "::endgroup::"
  fi
}

ingress_hosts() {
  kubectl get ingress -A -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}' 2>/dev/null | sort -u
}

https_ok() { # https_ok <host>: valid chain (curl verifies) and status < 400
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --retry 3 --retry-all-errors --retry-delay 5 --max-time 20 "https://$1/") || return 1
  echo "HTTP ${code}"
  [[ "$code" =~ ^[23] ]]
}

cert_ok() { # cert_ok <host>: not expiring within CERT_MIN_DAYS and not a Let's Encrypt staging cert
  local pem
  pem=$(openssl s_client -connect "$1:443" -servername "$1" </dev/null 2>/dev/null | openssl x509 2>/dev/null) || return 1
  [[ -n "$pem" ]] || return 1
  openssl x509 -noout -issuer -enddate <<< "$pem"
  if openssl x509 -noout -issuer <<< "$pem" | grep -qi 'staging'; then
    echo "issuer is a STAGING CA"; return 1
  fi
  openssl x509 -noout -checkend $((CERT_MIN_DAYS * 86400)) <<< "$pem"
}

endpoint_checks() {
  local hosts="${HOSTS:-}"
  [[ -n "$hosts" ]] || hosts=$(ingress_hosts)
  if [[ -z "$hosts" ]]; then
    record WARN "No ingress hosts found to smoke test"; return
  fi
  local h
  for h in $hosts; do
    check "HTTPS ${h}" https_ok "$h"
    check "TLS cert ${h} (>= ${CERT_MIN_DAYS}d, prod issuer)" cert_ok "$h"
  done
}

case "$MODE" in
  all) cluster_checks; endpoint_checks ;;
  cluster) cluster_checks ;;
  endpoints) endpoint_checks ;;
  *) echo "usage: $0 [all|cluster|endpoints]" >&2; exit 2 ;;
esac

# Summary (also to the GitHub job summary when running in Actions)
summary="### Health check (${MODE})"$'\n\n'"| Result | Check | Detail |"$'\n'"|---|---|---|"
for r in "${results[@]}"; do
  IFS=$'\t' read -r status name detail <<< "$r"
  case "$status" in PASS) icon="✅" ;; WARN) icon="⚠️" ;; *) icon="❌" ;; esac
  summary+=$'\n'"| ${icon} | ${name} | ${detail} |"
done
echo; echo "$summary"
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "$summary" >> "$GITHUB_STEP_SUMMARY"

exit "$failed"
