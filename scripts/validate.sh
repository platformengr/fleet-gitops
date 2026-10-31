#!/usr/bin/env bash
# Validate everything Argo CD and Terraform will read, before they read it.
# Runs locally and in CI (.github/workflows/validate.yaml). Every pull request
# must pass it; branch protection makes that a merge requirement.
#
#   scripts/validate.sh            run every check whose tool is installed
#   REQUIRE_ALL=1 scripts/validate.sh   fail if an optional tool is missing (CI)
#
# Required: python3 (+ pyyaml, jsonschema), helm, kustomize, kubeconform.
# Optional locally: yamllint, kyverno, terraform, shellcheck.
set -euo pipefail

cd "$(dirname "$0")/.."

CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
KUBECONFORM=(kubeconform -strict -summary -schema-location default -schema-location "$CRD_SCHEMAS")
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failed=0

section() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; failed=1; }
have() {
  command -v "$1" >/dev/null 2>&1 && return 0
  if [[ "${REQUIRE_ALL:-0}" == "1" ]]; then fail "$1 is not installed"; else printf '\033[33mSKIP\033[0m %s not installed\n' "$1"; fi
  return 1
}
for tool in python3 helm kustomize kubeconform; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 2; }
done

section "1. YAML syntax and style"
if have yamllint; then
  yamllint -s . || fail "yamllint"
fi

section "2. Fleet rules: inventory, products, ownership, generated Applications"
python3 scripts/fleet_check.py --quiet || fail "fleet_check.py (run it without --quiet for the full report)"

section "3. Argo CD manifests (root app, ApplicationSets, AppProject)"
"${KUBECONFORM[@]}" root-app.yaml applicationsets/ || fail "applicationsets"

section "4. Platform add-on overlays"
for overlay in addons/*/overlays/*/; do
  echo "-> ${overlay}"
  kustomize build "$overlay" | "${KUBECONFORM[@]}" -ignore-missing-schemas || fail "$overlay"
done

section "5. Product baselines and deployments, per product and environment"
helm lint charts/product-namespace charts/product-project >/dev/null || fail "helm lint"
for product in products/*/product.yaml; do
  name="$(basename "$(dirname "$product")")"
  helm template "$name" charts/product-project -f "$product" | "${KUBECONFORM[@]}" >/dev/null \
    || fail "${name}: charts/product-project"
  # environment<TAB>size<TAB>path for each environment entry
  python3 - "$product" <<'PY' > "$WORK/envs"
import sys, yaml
p = yaml.safe_load(open(sys.argv[1]))["product"]
for e in p["environments"]:
    print(e["environment"], e.get("size", "small"), p["path"], sep="\t")
PY
  while IFS=$'\t' read -r env size path; do
    echo "-> ${name} (${env}, ${size})"
    helm template "$name" charts/product-namespace -f "$product" --set "environment=${env}" --set "size=${size}" \
      > "$WORK/${name}-${env}-baseline.yaml" || { fail "${name} ${env}: baseline chart"; continue; }
    "${KUBECONFORM[@]}" "$WORK/${name}-${env}-baseline.yaml" >/dev/null || fail "${name} ${env}: baseline schema"
    if [[ -d "${path}/${env}" ]]; then
      kustomize build "${path}/${env}" > "$WORK/${name}-${env}-app.yaml" || { fail "${path}/${env}: kustomize build"; continue; }
      "${KUBECONFORM[@]}" -ignore-missing-schemas "$WORK/${name}-${env}-app.yaml" >/dev/null || fail "${path}/${env}: schema"
      # Everything must land in the product's namespace (the AppProject enforces it too).
      if grep -E '^  namespace: ' "$WORK/${name}-${env}-app.yaml" | grep -vqE "^  namespace: ${name}\$"; then
        fail "${path}/${env}: resources outside namespace ${name}"
      fi
    fi
  done < "$WORK/envs"
done

section "6. Policies: prod Kyverno rules against every product's manifests"
if have kyverno; then
  kustomize build addons/kyverno-policies/overlays/prod > "$WORK/policies.yaml"
  {
    echo "apiVersion: cli.kyverno.io/v1alpha1"
    echo "kind: Value"
    echo "metadata: { name: product-namespaces }"
    echo "namespaceSelector:"
    for product in products/*/product.yaml; do
      printf '  - name: %s\n    labels: { fleet.gitops/type: product }\n' "$(basename "$(dirname "$product")")"
    done
  } > "$WORK/values.yaml"
  shopt -s nullglob
  apps=("$WORK"/*-app.yaml)
  shopt -u nullglob
  if ((${#apps[@]})); then
    for app in "${apps[@]}"; do
      echo "-> $(basename "$app" -app.yaml)"
      if ! kyverno apply "$WORK/policies.yaml" --resource "$app" --values-file "$WORK/values.yaml" >/dev/null 2>&1; then
        kyverno apply "$WORK/policies.yaml" --resource "$app" --values-file "$WORK/values.yaml" --table 2>&1 | grep -E 'Fail|POLICY' || true
        fail "$(basename "$app" .yaml): Kyverno policy violation (see the Fail rows above)"
      fi
    done
  fi
fi

section "7. Terraform"
if have terraform; then
  terraform fmt -check -recursive infrastructure || fail "terraform fmt (run: terraform fmt -recursive infrastructure)"
  for root in infrastructure/*/; do
    [[ -f "${root}versions.tf" && "$root" != infrastructure/modules/ ]] || continue
    echo "-> ${root}"
    (cd "$root" && terraform init -backend=false -input=false >/dev/null && terraform validate -no-color) || fail "terraform validate ${root}"
  done
fi

section "8. Shell scripts"
if have shellcheck; then
  mapfile -t scripts < <(git ls-files '*.sh')
  ((${#scripts[@]})) && { shellcheck -x "${scripts[@]}" || fail "shellcheck"; }
fi

echo
if ((failed)); then
  echo "Validation failed."
  exit 1
fi
echo "All checks passed."
