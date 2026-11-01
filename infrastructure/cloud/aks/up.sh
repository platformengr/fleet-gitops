#!/usr/bin/env bash
# infrastructure/cloud/aks/up.sh: hub + dev + prod on Azure Kubernetes Service.
#
# Creates ${PREFIX}-hub/-dev/-prod in one resource group with managed identity,
# OIDC issuer + workload identity, Azure CNI overlay + Cilium (network policy),
# a tainted system pool and an autoscaling user pool, the stable upgrade
# channel and the Standard tier. Then installs Argo CD (HA) on the hub,
# registers the spokes and writes clusters/{dev,prod}.yaml.
#
# Usage: aks/up.sh [--fleet-dir DIR] [--dry-run] [--env-file FILE] [--skip-root-app] [--profile prod|local]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/argocd.sh
. "${SCRIPT_DIR}/../lib/argocd.sh"

usage() {
  cat <<'USAGE'
Usage: aks/up.sh [flags]

  --dry-run         print every mutating command instead of running it
  --env-file FILE   settings file (default: aks/env, else env.example)
  --skip-root-app   create, install and register only; do not apply root-app.yaml
  --profile NAME    Argo CD values profile: prod (default) or local
  -h, --help        show this help
USAGE
  fleet_dir_help
  echo '  (FLEET_REPO_DIR=DIR works too; reference fleet: https://github.com/platformengr/fleet-gitops)'
}

CLOUD_PROVIDER=aks
parse_common_flags usage "$@"
load_env "$SCRIPT_DIR" "${ENV_FILE}"
: "${REGION:=}"
ARGOCD_PROFILE="${ARGOCD_PROFILE:-prod}"

section "Preflight"
require_cmd az "https://learn.microsoft.com/cli/azure/install-azure-cli"
require_cmd kubectl "az aks install-cli"
require_cmd helm "https://helm.sh/docs/intro/install/"
require_var PREFIX REGION RESOURCE_GROUP
check_repo_url || true

if [[ -n "${AZ_SUBSCRIPTION}" ]]; then run az account set --subscription "$AZ_SUBSCRIPTION"; fi
if ! is_dry_run; then
  az account show -o none 2>/dev/null || die "not logged in: run 'az login'"
  info "subscription: $(az account show --query name -o tsv)"
fi

read -r -a TAG_ARGS <<<"$TAGS"
read -r -a ZONE_ARGS <<<"$ZONES"

section "Resource group ${RESOURCE_GROUP} (${REGION})"
run az group create --name "$RESOURCE_GROUP" --location "$REGION" --tags "${TAG_ARGS[@]}" -o none

cluster_exists() { az aks show -g "$RESOURCE_GROUP" -n "$1" -o none 2>/dev/null; }

create_cluster() {
  local name="$1" user_min="$2"
  section "AKS cluster ${name}"
  if ! is_dry_run && cluster_exists "$name"; then
    ok "${name} already exists"
  else
    local args=(az aks create
      --resource-group "$RESOURCE_GROUP" --name "$name" --location "$REGION"
      --tier "$AKS_TIER"
      --enable-managed-identity
      --enable-oidc-issuer --enable-workload-identity
      --network-plugin azure --network-plugin-mode overlay
      --network-dataplane "$NETWORK_DATAPLANE" --network-policy "$NETWORK_POLICY"
      --auto-upgrade-channel "$AUTO_UPGRADE_CHANNEL"
      --node-os-upgrade-channel "$NODE_OS_UPGRADE_CHANNEL"
      --nodepool-name system
      --node-vm-size "$SYSTEM_NODE_SIZE"
      --node-count "$SYSTEM_NODE_COUNT_MIN"
      --enable-cluster-autoscaler
      --min-count "$SYSTEM_NODE_COUNT_MIN" --max-count "$SYSTEM_NODE_COUNT_MAX"
      --nodepool-taints CriticalAddonsOnly=true:NoSchedule
      --generate-ssh-keys
      --tags "${TAG_ARGS[@]}"
      -o none)
    [[ -n "$K8S_VERSION" ]] && args+=(--kubernetes-version "$K8S_VERSION")
    [[ ${#ZONE_ARGS[@]} -gt 0 ]] && args+=(--zones "${ZONE_ARGS[@]}")
    [[ -n "$API_AUTHORIZED_IP_RANGES" ]] && args+=(--api-server-authorized-ip-ranges "$API_AUTHORIZED_IP_RANGES")
    run "${args[@]}"
  fi

  if ! is_dry_run && az aks nodepool show -g "$RESOURCE_GROUP" --cluster-name "$name" -n user -o none 2>/dev/null; then
    ok "user pool on ${name} already exists"
  else
    local np=(az aks nodepool add
      --resource-group "$RESOURCE_GROUP" --cluster-name "$name" --name user --mode User
      --node-vm-size "$NODE_SIZE" --node-count "$user_min"
      --enable-cluster-autoscaler --min-count "$user_min" --max-count "$NODE_COUNT_MAX"
      --tags "${TAG_ARGS[@]}"
      -o none)
    [[ -n "$K8S_VERSION" ]] && np+=(--kubernetes-version "$K8S_VERSION")
    [[ ${#ZONE_ARGS[@]} -gt 0 ]] && np+=(--zones "${ZONE_ARGS[@]}")
    run "${np[@]}"
  fi

  # Admin credentials are not used: get-credentials returns an Entra ID user
  # kubeconfig when Entra integration is enabled, else the cluster user one.
  run az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$name" \
    --context "${CONTEXT_PREFIX}-${name##*-}" --overwrite-existing
}

create_cluster "${PREFIX}-hub" "$HUB_NODE_COUNT_MIN"
create_cluster "${PREFIX}-dev" "$NODE_COUNT_MIN"
create_cluster "${PREFIX}-prod" "$NODE_COUNT_MIN"

bootstrap_fleet "${CONTEXT_PREFIX}-hub" "${CONTEXT_PREFIX}-dev" "${CONTEXT_PREFIX}-prod" "$REGION"

cat >&2 <<EOF

AKS notes:
- Workload identity is on (OIDC issuer: az aks show -g ${RESOURCE_GROUP} -n ${PREFIX}-hub --query oidcIssuerProfile.issuerUrl -o tsv).
  Lesson 10 uses it to replace the spoke tokens with argocd-k8s-auth azure.
- API servers are public${API_AUTHORIZED_IP_RANGES:+ (limited to ${API_AUTHORIZED_IP_RANGES})}. For prod, consider
  --enable-private-cluster or API Server VNet Integration.
- Tear down (deletes the clusters and the resource group): bootstrap/aks/down.sh
EOF
