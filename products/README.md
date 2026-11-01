# Products

One folder per product, each with a `product.yaml`: the declarative onboarding
request a product team makes to the platform. Owned jointly: the product team
proposes it, the platform team reviews it (see [CODEOWNERS](../.github/CODEOWNERS)).

```text
products/checkout/product.yaml        what the team asks for (this folder)
        |
        |  Argo CD ApplicationSets (applicationsets/product-*.yaml)
        v
hub:      AppProject checkout          which repo, which namespace, no cluster-scoped kinds
dev:      namespace checkout + baseline (quota, limits, network policy, RBAC, labels)
          Application checkout-dev  -> product-deployments/checkout/dev
prod:     namespace checkout + baseline
          Application checkout-prod -> product-deployments/checkout/prod
```

## Fields

See [schema.json](schema.json). `environment` selects clusters by the
`fleet.gitops/environment` label that Terraform puts on each Argo CD cluster
Secret from [clusters/*.yaml](../clusters/). Add a cluster with
`environment: prod` and every product with a `prod` environment lands on it.

## Why `product:` and not `metadata`/`spec`?

It looks like a Kubernetes resource but is a plain file read by an
ApplicationSet git generator. The matrix generator merges parameters from
every child generator into one namespace, and the cluster generator already
uses `name` and `metadata`. Keeping everything under `product:` avoids
collisions. The production evolution is a real CRD with a controller (or a
tool such as Kratix, Crossplane or a Backstage template) that writes the same
resources.

## Onboard a product

1. Open an issue with the **Onboard a product** form.
2. Copy `checkout/` to `products/<name>/`, edit `product.yaml`.
3. Add the deployment config under `product-deployments/<name>/<environment>/`.
4. Add the team to [CODEOWNERS](../.github/CODEOWNERS).
5. Open a pull request that says `Closes #<issue>`. CI validates it and lists
   the Applications Argo CD will generate.
6. After review and merge, watch them appear:
   `kubectl --context kind-platform -n argocd get applications -l fleet.gitops/product=<name>`.

## Offboarding

Deleting `product.yaml` deletes the Applications and the workloads. The
namespace itself is kept (`Prune=false`) so data is not lost by accident;
removing it is a reviewed, manual platform step.
