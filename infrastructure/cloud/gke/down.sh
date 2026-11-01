#!/usr/bin/env bash
# infrastructure/cloud/gke/down.sh: delete the GKE fleet created by up.sh.
# Deletes ${PREFIX}-prod/-dev/-hub and the kubeconfig contexts.
# Usage: gke/down.sh [--yes] [--dry-run] [--env-file FILE] [--fleet-dir DIR]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

usage() { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; fleet_dir_help; }
FLEET_DIR_OPTIONAL=1
parse_common_flags usage "$@"
load_env "$SCRIPT_DIR" "${ENV_FILE}"
if is_dry_run && [[ -z "$PROJECT_ID" ]]; then PROJECT_ID="<your-project-id>"; fi

require_cmd gcloud
require_cmd kubectl
require_var PROJECT_ID
LOCATION="${ZONE:-$REGION}"

CLUSTERS=("${PREFIX}-prod" "${PREFIX}-dev" "${PREFIX}-hub")
confirm "Delete GKE clusters ${CLUSTERS[*]} in ${PROJECT_ID}/${LOCATION}? This cannot be undone." \
  || die "aborted"

for c in "${CLUSTERS[@]}"; do
  if is_dry_run || gcloud container clusters describe "$c" --location "$LOCATION" --project "$PROJECT_ID" \
      --format='value(name)' >/dev/null 2>&1; then
    run gcloud container clusters delete "$c" --location "$LOCATION" --project "$PROJECT_ID" --quiet
  else
    info "${c} not found, skipping"
  fi
done

for s in hub dev prod; do
  if is_dry_run || kubectl config get-contexts -o name 2>/dev/null | grep -qx "${CONTEXT_PREFIX}-${s}"; then
    run kubectl config delete-context "${CONTEXT_PREFIX}-${s}"
  fi
done
ok "GKE fleet removed. Persistent disks from PVCs and load balancers may outlive clusters: check Compute Engine."
