#!/usr/bin/env bash
# bootstrap/aks/down.sh: delete the AKS fleet created by up.sh.
# Deletes ${PREFIX}-prod/-dev/-hub, then the resource group if up.sh created it
# (tag managed-by=fleet-gitops-bootstrap), and the kubeconfig contexts.
# Usage: bootstrap/aks/down.sh [--yes] [--dry-run] [--env-file FILE]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; }
parse_common_flags usage "$@"
load_env "$SCRIPT_DIR" "${ENV_FILE}"

require_cmd az
require_cmd kubectl
if [[ -n "${AZ_SUBSCRIPTION}" ]]; then run az account set --subscription "$AZ_SUBSCRIPTION"; fi

CLUSTERS=("${PREFIX}-prod" "${PREFIX}-dev" "${PREFIX}-hub")
confirm "Delete AKS clusters ${CLUSTERS[*]} in resource group ${RESOURCE_GROUP}? This cannot be undone." \
  || die "aborted"

for c in "${CLUSTERS[@]}"; do
  if is_dry_run || az aks show -g "$RESOURCE_GROUP" -n "$c" -o none 2>/dev/null; then
    run az aks delete --resource-group "$RESOURCE_GROUP" --name "$c" --yes
  else
    info "${c} not found, skipping"
  fi
done

managed_by=""
if ! is_dry_run; then
  managed_by="$(az group show -n "$RESOURCE_GROUP" --query 'tags."managed-by"' -o tsv 2>/dev/null || true)"
fi
if is_dry_run || [[ "$managed_by" == "fleet-gitops-bootstrap" ]]; then
  run az group delete --name "$RESOURCE_GROUP" --yes --no-wait
  info "resource group deletion continues in the background: az group show -n ${RESOURCE_GROUP}"
else
  warn "resource group ${RESOURCE_GROUP} was not created by up.sh (no managed-by tag); left in place"
fi

for s in hub dev prod; do
  if is_dry_run || kubectl config get-contexts -o name 2>/dev/null | grep -qx "${CONTEXT_PREFIX}-${s}"; then
    run kubectl config delete-context "${CONTEXT_PREFIX}-${s}"
  fi
done
ok "AKS fleet removed. Check the portal for leftovers (public IPs, disks) in MC_* groups."
