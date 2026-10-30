#!/usr/bin/env bash
# bootstrap/kind/up.sh: local fleet on kind.
#
# Creates three kind clusters (platform = Argo CD hub, dev, prod), installs
# Argo CD on the hub, registers dev and prod as spokes with declarative
# cluster Secrets, updates clusters/{dev,prod}.yaml with the spokes' Docker
# network addresses and applies root-app.yaml.
#
# Usage: bootstrap/kind/up.sh [--dry-run] [--no-git-check] [--skip-root-app] [--profile local|prod]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/argocd.sh
. "${SCRIPT_DIR}/../lib/argocd.sh"

usage() {
  cat <<'USAGE'
Usage: bootstrap/kind/up.sh [flags]

  --dry-run         print every mutating command instead of running it
  --no-git-check    skip the check that root-app.yaml points at your Git remote
  --skip-root-app   install and register only; do not apply root-app.yaml
  --profile NAME    Argo CD values profile: local (default) or prod
  -h, --help        show this help

Environment:
  KIND_NODE_IMAGE   e.g. kindest/node:v1.33.1 to pin the Kubernetes version
  HUB_NAME          kind cluster name for the hub (default: platform)
  REPO_URL          Git URL Argo CD should read (default: value in root-app.yaml)
USAGE
}

ARGOCD_PROFILE="${ARGOCD_PROFILE:-local}"
parse_common_flags usage "$@"

HUB_NAME="${HUB_NAME:-platform}"
SPOKES=(dev prod)
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-}"
REPO_URL="${REPO_URL:-$(manifest_repo_url)}"

section "Preflight"
require_cmd docker "https://docs.docker.com/get-docker/"
require_cmd kind "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
require_cmd kubectl
require_cmd helm "https://helm.sh/docs/intro/install/"
require_cmd git

if ! is_dry_run; then
  docker info >/dev/null 2>&1 || die "Docker is not running"
fi

git_remote_hint() {
  local origin
  origin="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  [[ -n "$origin" ]] || { warn "no 'origin' remote; Argo CD will read ${REPO_URL}"; return 0; }
  # Compare host/owner/repo, ignoring scheme, ssh form and .git suffix.
  norm() { printf '%s' "$1" | sed -E 's#^(https?://|git@)##; s#:#/#; s#\.git$##; s#/$##' | tr '[:upper:]' '[:lower:]'; }
  if [[ "$(norm "$origin")" != "$(norm "$REPO_URL")" ]]; then
    err "root-app.yaml points at ${REPO_URL} but your origin is ${origin}."
    err "Argo CD reads Git, not your laptop. Point the manifests at your fork:"
    err "  scripts/set-repo-url.sh https://github.com/<you>/fleet-gitops.git && git commit -am 'Use my fork' && git push"
    err "or re-run with --no-git-check if this is intentional."
    exit 1
  fi
  ok "manifests point at your origin (${origin})"
}
if [[ "${NO_GIT_CHECK}" != "1" ]]; then git_remote_hint; fi

cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$1"; }

section "Create kind clusters"
for c in "$HUB_NAME" "${SPOKES[@]}"; do
  if ! is_dry_run && cluster_exists "$c"; then
    ok "kind cluster '$c' already exists"
    continue
  fi
  args=(kind create cluster --name "$c" --wait 120s)
  [[ -n "$KIND_NODE_IMAGE" ]] && args+=(--image "$KIND_NODE_IMAGE")
  run "${args[@]}"
done

# Spokes are reached from the hub over the shared "kind" Docker network, so
# the API URL is the control-plane container IP, not the 127.0.0.1 port your
# kubeconfig uses. The kind API server certificate already includes this IP.
spoke_server() {
  local ip
  ip="$(capture "<${1}-control-plane-ip>" docker inspect -f \
    '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "${1}-control-plane")"
  [[ -n "$ip" ]] || die "could not find the kind network IP of ${1}-control-plane"
  printf 'https://%s:6443' "$ip"
}

install_argocd_hub "kind-${HUB_NAME}" "$ARGOCD_PROFILE"

section "Update cluster inventory"
for c in "${SPOKES[@]}"; do
  set_inventory_server "$c" "$(spoke_server "$c")"
done

for c in "${SPOKES[@]}"; do
  register_spoke "kind-${HUB_NAME}" "kind-${c}" "$c" "$c" "$(spoke_server "$c")" "" "local"
done

if [[ "${SKIP_ROOT_APP}" != "1" ]]; then
  apply_root_app "kind-${HUB_NAME}"
fi

section "Next steps"
print_argocd_access "kind-${HUB_NAME}"
cat >&2 <<EOF

1. Argo CD reads the inventory from Git, so commit and push the new endpoints:
     git diff clusters/
     git add clusters/dev.yaml clusters/prod.yaml
     git commit -m "Use my local kind endpoints" && git push
   Kind container IPs change when clusters are recreated; re-run this script then.
2. Watch the fleet converge:
     kubectl --context kind-${HUB_NAME} -n argocd get applicationsets,applications
3. Tear down with: bootstrap/kind/down.sh
EOF
