# Product onboarding flow

How one file, `products/<name>/product.yaml`, becomes namespaces, guardrails and running Applications on every matching cluster.

```text
Issue "Onboard a product"
   │
   v
PR: products/catalog/product.yaml + product-deployments/catalog/{dev,prod}/ + CODEOWNERS line
   │  validate: schema, environments exist, folders exist, owners set, policies pass
   │  plan:     + product-catalog-project, catalog-dev-baseline, catalog-dev, catalog-prod-baseline, catalog-prod
   │  production-gate: product.yaml can add prod, so approval is required
   v
merge ──> Argo CD (hub)
            ├─ product-projects   ─> AppProject "catalog"            (hub)
            ├─ product-namespaces ─> namespace catalog + baseline    (every cluster with environment dev / prod)
            └─ product-apps       ─> catalog-dev, catalog-prod        (project "catalog", namespace catalog only)
```

## 1. The declaration

[products/checkout/product.yaml](../products/checkout/product.yaml) is the example. Each entry in `environments` names an environment, not a cluster: the platform decides which clusters serve an environment by labelling them, so adding a second prod cluster needs no product change.

## 2. The AppProject (hub)

[charts/product-project](../charts/product-project/) creates one AppProject per product:

- `sourceRepos`: only the product's repository
- `destinations`: only the product's namespace, on any cluster
- `clusterResourceWhitelist: []`: no cluster-scoped objects (no Namespaces, no CRDs, no ClusterRoles)
- blacklisted: `ResourceQuota`, `LimitRange`, `Role`, `RoleBinding`, the objects the platform owns

A product Application that tries to deploy elsewhere fails in Argo CD, before it reaches a cluster.

## 3. The namespace baseline (each cluster)

[charts/product-namespace](../charts/product-namespace/), deployed by the platform's own project:

| Object | From |
| --- | --- |
| Namespace with `fleet.gitops/{product,owner,environment,cost-center,type}` labels and Pod Security labels | `name`, `owner`, `costCenter`, `podSecurity` |
| ResourceQuota, LimitRange | `size` of that environment entry |
| NetworkPolicies: default deny, same namespace, from ingress | fixed |
| RoleBinding: group `<owner>` gets `edit` | `owner` |
| SecretStore (optional) | `secretStore` values |

The namespace is annotated `Prune=false`: removing a product never deletes its data by accident.

## 4. The Application (each cluster)

`<product>-<cluster>` reads `<repository>/<path>/<environment>` with automated sync, prune and self-heal, and retries until the baseline (namespace) exists.

## Try it locally

```bash
python3 scripts/fleet_check.py                      # the Applications the repo generates
helm template checkout charts/product-namespace \
  -f products/checkout/product.yaml --set environment=prod --set size=medium
kustomize build product-deployments/checkout/prod
```

On kind, act as the product team:

```bash
kubectl --context kind-dev -n checkout get deploy --as=dev-user --as-group=team-checkout       # allowed
kubectl --context kind-dev -n checkout delete networkpolicy default-deny-ingress \
  --as=dev-user --as-group=team-checkout                                                    # denied by Kyverno
kubectl --context kind-dev -n checkout get resourcequota --as=dev-user --as-group=team-checkout # read-only
```
