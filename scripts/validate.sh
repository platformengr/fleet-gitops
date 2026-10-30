#!/usr/bin/env bash
# Validate everything Argo CD will read, before Argo CD reads it.
# Runs locally and in CI (.github/workflows/validate.yaml).
#
# Requires: kustomize, helm, kubeconform. Optional: shellcheck.
set -euo pipefail

cd "$(dirname "$0")/.."

CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
KUBECONFORM=(kubeconform -strict -summary -schema-location default -schema-location "$CRD_SCHEMAS")
failed=0

section() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; failed=1; }

section "Argo CD manifests (root app + applicationsets)"
"${KUBECONFORM[@]}" root-app.yaml applicationsets/ || fail "applicationsets"

section "Kustomize overlays"
for overlay in addons/*/overlays/*/; do
  echo "-> ${overlay}"
  # Kyverno ClusterPolicies are CRDs; -ignore-missing-schemas keeps this offline-friendly.
  kustomize build "$overlay" | "${KUBECONFORM[@]}" -ignore-missing-schemas || fail "$overlay"
done

section "Tenant namespace chart against every request"
helm lint charts/tenant-namespace >/dev/null || fail "helm lint tenant-namespace"
for request in requests/namespaces/*.yaml; do
  for env in dev prod; do
    echo "-> ${request} (${env})"
    # The request file wraps values under `namespace:`, matching the chart's values shape.
    helm template t charts/tenant-namespace -f "$request" --set "cluster.environment=${env}" \
      | "${KUBECONFORM[@]}" || fail "${request} ${env}"
  done
done

section "Cluster inventory"
for cluster in clusters/*.yaml; do
  for field in name server environment upgradeWave region; do
    grep -qE "^${field}:" "$cluster" || fail "${cluster}: missing ${field}"
  done
  env="$(sed -n 's/^environment: *//p' "$cluster")"
  for addon in namespaces kyverno-policies; do
    [[ -d "addons/${addon}/overlays/${env}" ]] || fail "${cluster}: no addons/${addon}/overlays/${env}"
  done
done

section "Examples"
for example in examples/*/; do
  echo "-> ${example}"
  kustomize build "$example" | "${KUBECONFORM[@]}" -ignore-missing-schemas || fail "$example"
done

if command -v shellcheck >/dev/null 2>&1; then
  section "Shell scripts"
  mapfile -t scripts < <(git ls-files '*.sh')
  ((${#scripts[@]})) && { shellcheck -x "${scripts[@]}" || fail "shellcheck"; }
fi

echo
if ((failed)); then
  echo "Validation failed."
  exit 1
fi
echo "All checks passed."
