#!/usr/bin/env bash
# infrastructure/cloud/eks/up.sh: hub + dev + prod on Amazon EKS (eksctl).
#
# Renders an eksctl ClusterConfig per cluster (bootstrap/eks/.generated/) with
# OIDC + the EKS Pod Identity agent, the EBS CSI driver, a system and a worker
# managed node group in private subnets, control plane logging and a
# public+private API endpoint. Then installs Argo CD (HA) on the hub,
# registers the spokes and writes clusters/{dev,prod}.yaml.
#
# Usage: eks/up.sh [--fleet-dir DIR] [--dry-run] [--env-file FILE] [--skip-root-app] [--profile prod|local]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/argocd.sh
. "${SCRIPT_DIR}/../lib/argocd.sh"

usage() {
  cat <<'USAGE'
Usage: eks/up.sh [flags]

  --dry-run         print every mutating command (and the rendered eksctl config) instead of running it
  --env-file FILE   settings file (default: eks/env, else env.example)
  --skip-root-app   create, install and register only; do not apply root-app.yaml
  --profile NAME    Argo CD values profile: prod (default) or local
  -h, --help        show this help
USAGE
  fleet_dir_help
  echo '  (FLEET_REPO_DIR=DIR works too; reference fleet: https://github.com/platformengr/fleet-gitops)'
}

CLOUD_PROVIDER=eks
parse_common_flags usage "$@"
load_env "$SCRIPT_DIR" "${ENV_FILE}"
: "${REGION:=}"
ARGOCD_PROFILE="${ARGOCD_PROFILE:-prod}"
if [[ -n "${AWS_PROFILE}" ]]; then export AWS_PROFILE; else unset AWS_PROFILE; fi

section "Preflight"
require_cmd aws "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
require_cmd eksctl "https://eksctl.io/installation/"
require_cmd kubectl
require_cmd helm "https://helm.sh/docs/intro/install/"
require_var PREFIX REGION
check_repo_url || true

if ! is_dry_run; then
  aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1 \
    || die "no AWS credentials: run 'aws configure sso' / 'aws sso login' or set AWS_PROFILE"
  info "AWS identity: $(aws sts get-caller-identity --query Arn --output text)"
fi

GEN_DIR="${SCRIPT_DIR}/.generated"
: "${TAGS:=}" "${API_PUBLIC_ACCESS_CIDRS:=}"

# render_config NAME WORKER_MIN  prints an eksctl ClusterConfig.
render_config() {
  local name="$1" worker_min="$2" tags="" kv cidrs=""
  local IFS_OLD="$IFS"; IFS=','
  for kv in $TAGS; do tags+="    ${kv%%=*}: \"${kv#*=}\""$'\n'; done
  if [[ -n "$API_PUBLIC_ACCESS_CIDRS" ]]; then
    for kv in $API_PUBLIC_ACCESS_CIDRS; do cidrs+="\"${kv}\", "; done
    cidrs="  publicAccessCIDRs: [${cidrs%, }]"
  fi
  IFS="$IFS_OLD"
  cat <<EOF
# Rendered by bootstrap/eks/up.sh. Edit env, not this file.
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${name}
  region: ${REGION}
$( [[ -n "$K8S_VERSION" ]] && printf '  version: "%s"\n' "$K8S_VERSION" )
  tags:
${tags%$'\n'}
iam:
  # OIDC provider for IRSA. Pod Identity (below) is the newer option; both work.
  withOIDC: true
accessConfig:
  # EKS access entries instead of the aws-auth ConfigMap.
  authenticationMode: API
vpc:
  nat:
    gateway: ${NAT_GATEWAY}
  clusterEndpoints:
    publicAccess: true
    privateAccess: true
${cidrs}
addonsConfig:
  # Create Pod Identity associations for add-ons that need AWS permissions (EBS CSI, VPC CNI).
  autoApplyPodIdentityAssociations: true
addons:
  - name: eks-pod-identity-agent
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: aws-ebs-csi-driver
managedNodeGroups:
  - name: system
    instanceType: ${SYSTEM_NODE_SIZE}
    minSize: ${SYSTEM_NODE_COUNT_MIN}
    maxSize: ${SYSTEM_NODE_COUNT_MAX}
    desiredCapacity: ${SYSTEM_NODE_COUNT_MIN}
    privateNetworking: true
    volumeSize: ${NODE_VOLUME_SIZE}
    volumeEncrypted: true
    labels: { role: system }
    # Not tainted: EKS has no system-pool scheduling contract like AKS, and an
    # untolerated taint would strand add-ons. Taint once Karpenter owns workloads.
  - name: workers
    instanceType: ${NODE_SIZE}
    minSize: ${worker_min}
    maxSize: ${NODE_COUNT_MAX}
    desiredCapacity: ${worker_min}
    privateNetworking: true
    volumeSize: ${NODE_VOLUME_SIZE}
    volumeEncrypted: true
    labels: { role: workers }
cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator"]
EOF
}

cluster_exists() { eksctl get cluster --name "$1" --region "$REGION" >/dev/null 2>&1; }

create_cluster() {
  local name="$1" worker_min="$2" ctx="${CONTEXT_PREFIX}-${1##*-}" file
  section "EKS cluster ${name}"
  file="${GEN_DIR}/${name}.yaml"
  if is_dry_run; then
    _print_cmd "# render ${file#"${BOOTSTRAP_DIR}"/}"
    render_config "$name" "$worker_min" | sed 's/^/    | /' >&2
  else
    mkdir -p "$GEN_DIR"
    render_config "$name" "$worker_min" > "$file"
  fi
  if ! is_dry_run && cluster_exists "$name"; then
    ok "${name} already exists (to change node groups: eksctl upgrade / create nodegroup -f ${file})"
  else
    run eksctl create cluster -f "$file" --write-kubeconfig=false
  fi
  run aws eks update-kubeconfig --name "$name" --region "$REGION" --alias "$ctx"
}

create_cluster "${PREFIX}-hub" "$HUB_NODE_COUNT_MIN"
create_cluster "${PREFIX}-dev" "$NODE_COUNT_MIN"
create_cluster "${PREFIX}-prod" "$NODE_COUNT_MIN"

bootstrap_fleet "${CONTEXT_PREFIX}-hub" "${CONTEXT_PREFIX}-dev" "${CONTEXT_PREFIX}-prod" "$REGION"

cat >&2 <<EOF

EKS notes:
- The IAM identity that ran eksctl is the cluster creator admin (access entry).
  Add access entries for your team: aws eks create-access-entry / associate-access-policy.
- Node groups have min/max but nothing scales them yet: install Karpenter or Cluster Autoscaler.
- Lesson 10 replaces the spoke tokens with an IAM role (IRSA or Pod Identity) and awsAuthConfig.
- Tear down: bootstrap/eks/down.sh
EOF
