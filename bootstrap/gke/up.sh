#!/usr/bin/env bash
# bootstrap/gke/up.sh: hub + dev + prod on Google Kubernetes Engine (Standard).
#
# Creates ${PREFIX}-hub/-dev/-prod (regional by default, zonal if ZONE is set)
# with Workload Identity Federation, Dataplane V2 (network policy), the regular
# release channel, shielded nodes and an autoscaling node pool. Then installs
# Argo CD (HA) on the hub, registers the spokes and writes clusters/{dev,prod}.yaml.
#
# Usage: bootstrap/gke/up.sh [--dry-run] [--env-file FILE] [--skip-root-app] [--profile prod|local]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/argocd.sh
. "${SCRIPT_DIR}/../lib/argocd.sh"

usage() {
  cat <<'USAGE'
Usage: bootstrap/gke/up.sh [flags]

  --dry-run         print every mutating command instead of running it
  --env-file FILE   settings file (default: bootstrap/gke/env, else env.example)
  --skip-root-app   create, install and register only; do not apply root-app.yaml
  --profile NAME    Argo CD values profile: prod (default) or local
  -h, --help        show this help
USAGE
}

parse_common_flags usage "$@"
load_env "$SCRIPT_DIR" "${ENV_FILE}"
ARGOCD_PROFILE="${ARGOCD_PROFILE:-prod}"
if is_dry_run && [[ -z "$PROJECT_ID" ]]; then PROJECT_ID="<your-project-id>"; fi

section "Preflight"
require_cmd gcloud "https://cloud.google.com/sdk/docs/install"
require_cmd gke-gcloud-auth-plugin "gcloud components install gke-gcloud-auth-plugin"
require_cmd kubectl
require_cmd helm "https://helm.sh/docs/intro/install/"
require_var PROJECT_ID PREFIX REGION
check_repo_url || true

LOCATION="${ZONE:-$REGION}"
info "project ${PROJECT_ID}, location ${LOCATION} ($([[ -n "$ZONE" ]] && echo zonal || echo regional))"

run gcloud services enable container.googleapis.com --project "$PROJECT_ID"

cluster_exists() {
  gcloud container clusters describe "$1" --location "$LOCATION" --project "$PROJECT_ID" \
    --format='value(name)' >/dev/null 2>&1
}

create_cluster() {
  local name="$1" ctx="${CONTEXT_PREFIX}-${1##*-}"
  section "GKE cluster ${name}"
  if ! is_dry_run && cluster_exists "$name"; then
    ok "${name} already exists"
  else
    local args=(gcloud container clusters create "$name"
      --project "$PROJECT_ID" --location "$LOCATION"
      --release-channel "$RELEASE_CHANNEL"
      --workload-pool "${PROJECT_ID}.svc.id.goog"
      --enable-dataplane-v2
      --enable-ip-alias
      --network "$NETWORK"
      --enable-shielded-nodes --shielded-secure-boot --shielded-integrity-monitoring
      --workload-metadata GKE_METADATA
      --machine-type "$NODE_SIZE"
      --disk-type pd-balanced --disk-size "$NODE_DISK_SIZE"
      --num-nodes "$NODE_COUNT_MIN"
      --enable-autoscaling --min-nodes "$NODE_COUNT_MIN" --max-nodes "$NODE_COUNT_MAX"
      --enable-autorepair --enable-autoupgrade
      --labels "$LABELS")
    [[ -n "$SUBNETWORK" ]] && args+=(--subnetwork "$SUBNETWORK")
    [[ -n "$K8S_VERSION" ]] && args+=(--cluster-version "$K8S_VERSION")
    [[ -n "$MASTER_AUTHORIZED_NETWORKS" ]] && args+=(--enable-master-authorized-networks \
      --master-authorized-networks "$MASTER_AUTHORIZED_NETWORKS")
    [[ "$PRIVATE_NODES" == "true" ]] && args+=(--enable-private-nodes)
    run "${args[@]}"
  fi

  run gcloud container clusters get-credentials "$name" --location "$LOCATION" --project "$PROJECT_ID"
  rename_context "gke_${PROJECT_ID}_${LOCATION}_${name}" "$ctx"
}

create_cluster "${PREFIX}-hub"
create_cluster "${PREFIX}-dev"
create_cluster "${PREFIX}-prod"

bootstrap_fleet "${CONTEXT_PREFIX}-hub" "${CONTEXT_PREFIX}-dev" "${CONTEXT_PREFIX}-prod" "$REGION"

cat >&2 <<EOF

GKE notes:
- Workload Identity pool: ${PROJECT_ID}.svc.id.goog. Lesson 10 uses it to replace
  the spoke tokens with argocd-k8s-auth gcp (or GKE Fleet / Connect Gateway).
- Control planes are public${MASTER_AUTHORIZED_NETWORKS:+ (limited to ${MASTER_AUTHORIZED_NETWORKS})}. For prod, use
  authorized networks or private endpoints.
- Tear down: bootstrap/gke/down.sh
EOF
