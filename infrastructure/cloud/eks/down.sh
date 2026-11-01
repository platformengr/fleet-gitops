#!/usr/bin/env bash
# infrastructure/cloud/eks/down.sh: delete the EKS fleet created by up.sh.
# Deletes ${PREFIX}-prod/-dev/-hub with eksctl (VPCs, NAT gateways and node
# groups included) and the kubeconfig contexts.
# Usage: eks/down.sh [--yes] [--dry-run] [--env-file FILE] [--fleet-dir DIR]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; fleet_dir_help; }
FLEET_DIR_OPTIONAL=1
parse_common_flags usage "$@"
load_env "$SCRIPT_DIR" "${ENV_FILE}"
: "${REGION:=}"
if [[ -n "${AWS_PROFILE}" ]]; then export AWS_PROFILE; else unset AWS_PROFILE; fi

require_cmd eksctl
require_cmd kubectl

CLUSTERS=("${PREFIX}-prod" "${PREFIX}-dev" "${PREFIX}-hub")
confirm "Delete EKS clusters ${CLUSTERS[*]} in ${REGION}? This cannot be undone." || die "aborted"

for c in "${CLUSTERS[@]}"; do
  if is_dry_run || eksctl get cluster --name "$c" --region "$REGION" >/dev/null 2>&1; then
    # Delete LoadBalancer Services first, otherwise their ELBs can block VPC deletion.
    if ! is_dry_run; then
      kubectl --context "${CONTEXT_PREFIX}-${c##*-}" get svc -A \
        -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | while read -r ns svc; do
            [[ -n "$ns" ]] && run kubectl --context "${CONTEXT_PREFIX}-${c##*-}" -n "$ns" delete svc "$svc" --wait=false
          done || true
    fi
    run eksctl delete cluster --name "$c" --region "$REGION" --wait
  else
    info "${c} not found, skipping"
  fi
done

for s in hub dev prod; do
  if is_dry_run || kubectl config get-contexts -o name 2>/dev/null | grep -qx "${CONTEXT_PREFIX}-${s}"; then
    run kubectl config delete-context "${CONTEXT_PREFIX}-${s}"
  fi
done
run rm -rf "${SCRIPT_DIR}/.generated"
ok "EKS fleet removed. Check CloudFormation for stacks named eksctl-${PREFIX}-* in DELETE_FAILED."
