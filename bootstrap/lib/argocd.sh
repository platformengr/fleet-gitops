# shellcheck shell=bash
# bootstrap/lib/argocd.sh: install Argo CD on the hub, register spokes, apply the root app.
# Requires lib/common.sh to be sourced first.
#
#   install_argocd_hub <hub-ctx> [profile]          profile: local (default) | prod (HA)
#   register_spoke <hub-ctx> <spoke-ctx> <name> <environment> [server] [upgradeWave] [region]
#   apply_root_app <hub-ctx>
#   print_argocd_access <hub-ctx>

# Pinned Helm chart version for argo/argo-cd (chart 7.7.x ships Argo CD v2.13).
# Renovate bumps this line (regex manager in renovate.json); keep the exact form:
#   ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-X.Y.Z}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-7.7.11}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_RELEASE="${ARGOCD_RELEASE:-argocd}"
ARGOCD_HELM_REPO="${ARGOCD_HELM_REPO:-https://argoproj.github.io/argo-helm}"

# Service account Argo CD uses on each spoke (same name `argocd cluster add` uses).
SPOKE_SA_NAMESPACE="${SPOKE_SA_NAMESPACE:-kube-system}"
SPOKE_SA_NAME="${SPOKE_SA_NAME:-argocd-manager}"

# install_argocd_hub HUB_CONTEXT [PROFILE]
install_argocd_hub() {
  local ctx="$1" profile="${2:-${ARGOCD_PROFILE:-local}}"
  local values="${BOOTSTRAP_DIR}/argocd/values-${profile}.yaml"
  [[ -f "$values" ]] || die "unknown Argo CD profile '$profile' (no ${values})"

  section "Install Argo CD ${ARGOCD_CHART_VERSION} (profile: ${profile}) on ${ctx}"
  run helm repo add argo "$ARGOCD_HELM_REPO" --force-update
  run helm repo update argo
  run helm upgrade --install "$ARGOCD_RELEASE" argo/argo-cd \
    --kube-context "$ctx" \
    --namespace "$ARGOCD_NAMESPACE" --create-namespace \
    --version "$ARGOCD_CHART_VERSION" \
    --values "$values" \
    --wait --timeout 15m
  ok "Argo CD installed on ${ctx}"
}

# _spoke_rbac_manifest  ServiceAccount + cluster-admin-like role + long-lived token Secret.
# This mirrors what `argocd cluster add` creates, but is declarative and reviewable.
# Tighten the ClusterRole once you know which kinds your fleet deploys.
_spoke_rbac_manifest() {
  cat <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SPOKE_SA_NAME}
  namespace: ${SPOKE_SA_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: fleet-gitops-bootstrap
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${SPOKE_SA_NAME}-role
  labels:
    app.kubernetes.io/managed-by: fleet-gitops-bootstrap
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
  - nonResourceURLs: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${SPOKE_SA_NAME}-role-binding
  labels:
    app.kubernetes.io/managed-by: fleet-gitops-bootstrap
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${SPOKE_SA_NAME}-role
subjects:
  - kind: ServiceAccount
    name: ${SPOKE_SA_NAME}
    namespace: ${SPOKE_SA_NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SPOKE_SA_NAME}-token
  namespace: ${SPOKE_SA_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SPOKE_SA_NAME}
type: kubernetes.io/service-account-token
EOF
}

# _cluster_secret_manifest NAME SERVER ENV WAVE REGION CONFIG_JSON
# Declarative Argo CD cluster Secret. The fleet.gitops/* labels let cluster
# generators select spokes by environment / region / wave.
_cluster_secret_manifest() {
  local name="$1" server="$2" env="$3" wave="$4" region="$5" config="$6"
  cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${name}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: cluster
    app.kubernetes.io/managed-by: fleet-gitops-bootstrap
    fleet.gitops/environment: "${env}"
    fleet.gitops/region: "${region}"
    fleet.gitops/upgrade-wave: "${wave}"
type: Opaque
stringData:
  name: ${name}
  server: ${server}
  config: |
    ${config}
EOF
}

# register_spoke HUB_CTX SPOKE_CTX NAME ENVIRONMENT [SERVER] [UPGRADE_WAVE] [REGION]
#
# Portable default: a long-lived ServiceAccount token on the spoke, stored in a
# cluster Secret on the hub. It works on kind, AKS, EKS and GKE alike.
# Treat it as a stepping stone: lesson 10 swaps it for workload identity, so no
# static credential exists at all. The replacement `config` blocks are:
#
#   AKS (Argo CD controller + server use Azure Workload Identity; needs the
#   azure.workload.identity/use label + client-id annotation on their SAs, and
#   the identity granted "Azure Kubernetes Service RBAC Cluster Admin" on the spoke):
#     {"execProviderConfig": {"command": "argocd-k8s-auth", "apiVersion": "client.authentication.k8s.io/v1beta1",
#       "env": {"AAD_ENVIRONMENT_NAME": "AzurePublicCloud", "AAD_LOGIN_METHOD": "workloadidentity"},
#       "args": ["azure"]},
#      "tlsClientConfig": {"insecure": false, "caData": "<spoke CA base64>"}}
#
#   EKS (IRSA or EKS Pod Identity role on the Argo CD SAs, plus an EKS access
#   entry for that role on the spoke; awsAuthConfig makes Argo CD call argocd-k8s-auth aws):
#     {"awsAuthConfig": {"clusterName": "<eks-cluster-name>", "roleARN": "arn:aws:iam::<acct>:role/<spoke-deployer>"},
#      "tlsClientConfig": {"insecure": false, "caData": "<spoke CA base64>"}}
#
#   GKE (GKE Workload Identity Federation for the Argo CD SAs, the Google SA
#   granted roles/container.developer or a Kubernetes RBAC binding on the spoke):
#     {"execProviderConfig": {"command": "argocd-k8s-auth", "apiVersion": "client.authentication.k8s.io/v1beta1",
#       "args": ["gcp"]},
#      "tlsClientConfig": {"insecure": false, "caData": "<spoke CA base64>"}}
register_spoke() {
  local hub="$1" spoke="$2" name="$3" env="$4" server="${5:-}" wave="${6:-}" region="${7:-local}"
  if [[ -z "$wave" ]]; then
    case "$env" in dev) wave=0 ;; staging) wave=1 ;; prod) wave=1 ;; *) wave=0 ;; esac
  fi
  if [[ -z "$server" ]]; then server="$(context_server "$spoke")"; fi

  section "Register spoke '${name}' (${env}, wave ${wave}) from ${spoke} on hub ${hub}"
  _spoke_rbac_manifest | run_stdin "argocd-manager ServiceAccount, RBAC, token Secret" \
    kubectl --context "$spoke" apply -f -

  wait_for 120 "token for ${SPOKE_SA_NAME} on ${spoke}" \
    _spoke_token_ready "$spoke"

  local token ca config
  if is_dry_run; then
    token="<redacted>"; ca="<spoke-ca-base64>"
  else
    token="$(kubectl --context "$spoke" -n "$SPOKE_SA_NAMESPACE" get secret "${SPOKE_SA_NAME}-token" \
      -o 'jsonpath={.data.token}' | base64 --decode)"
    ca="$(kubectl --context "$spoke" -n "$SPOKE_SA_NAMESPACE" get secret "${SPOKE_SA_NAME}-token" \
      -o 'jsonpath={.data.ca\.crt}')"
    [[ -n "$token" && -n "$ca" ]] || die "could not read token/CA for ${SPOKE_SA_NAME} on ${spoke}"
  fi
  config="$(printf '{"bearerToken":"%s","tlsClientConfig":{"insecure":false,"caData":"%s"}}' "$token" "$ca")"

  _cluster_secret_manifest "$name" "$server" "$env" "$wave" "$region" "$config" \
    | run_stdin "cluster Secret cluster-${name} (token redacted in dry-run)" \
      kubectl --context "$hub" apply -f -
  ok "spoke ${name} registered as ${server}"
}

_spoke_token_ready() {
  local t
  t="$(kubectl --context "$1" -n "$SPOKE_SA_NAMESPACE" get secret "${SPOKE_SA_NAME}-token" \
    -o 'jsonpath={.data.token}' 2>/dev/null)"
  [[ -n "$t" ]]
}

# apply_root_app HUB_CTX  applies root-app.yaml (app-of-apps) to the hub.
apply_root_app() {
  local hub="$1"
  section "Apply root Application on ${hub}"
  check_repo_url || warn "Applying anyway; Argo CD will read $(manifest_repo_url)."
  run kubectl --context "$hub" apply -f "${REPO_ROOT}/root-app.yaml"
  ok "root app applied; ApplicationSets will appear as Argo CD syncs from Git"
}

# print_argocd_access HUB_CTX
print_argocd_access() {
  local hub="$1"
  cat >&2 <<EOF

Argo CD UI:
  kubectl --context ${hub} -n ${ARGOCD_NAMESPACE} port-forward svc/${ARGOCD_RELEASE}-server 8080:443
  open https://localhost:8080   (user: admin)
  kubectl --context ${hub} -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret \\
    -o jsonpath='{.data.password}' | base64 --decode; echo
  Delete argocd-initial-admin-secret after you set up SSO (lesson 09).
EOF
}

# bootstrap_fleet HUB_CTX DEV_CTX PROD_CTX REGION
# Shared tail of the cloud up.sh scripts: Argo CD (prod profile) on the hub,
# register dev + prod, write clusters/{dev,prod}.yaml, apply the root app.
bootstrap_fleet() {
  local hub="$1" dev="$2" prod="$3" region="$4" dev_server prod_server
  install_argocd_hub "$hub" "${ARGOCD_PROFILE:-prod}"

  dev_server="$(context_server "$dev")"
  prod_server="$(context_server "$prod")"

  section "Update cluster inventory"
  write_inventory dev "$dev_server" dev 0 "$region"
  write_inventory prod "$prod_server" prod 1 "$region"

  register_spoke "$hub" "$dev" dev dev "$dev_server" 0 "$region"
  register_spoke "$hub" "$prod" prod prod "$prod_server" 1 "$region"

  if [[ "${SKIP_ROOT_APP:-0}" != "1" ]]; then apply_root_app "$hub"; fi

  section "Next steps"
  print_argocd_access "$hub"
  cat >&2 <<NEXT

1. Commit and push the inventory so Argo CD sees the real API endpoints:
     git diff clusters/
     git add clusters/ && git commit -m "Register cloud spokes" && git push
2. lokiEndpoint in clusters/*.yaml is cluster-local DNS; spokes in other
   clusters cannot resolve it. Expose Loki on an internal LB (lesson 07).
3. Spokes use a long-lived ServiceAccount token today. Move to workload
   identity (lesson 10) and delete the ${SPOKE_SA_NAME}-token Secrets.
4. Watch: kubectl --context ${hub} -n ${ARGOCD_NAMESPACE} get applicationsets,applications
NEXT
}
