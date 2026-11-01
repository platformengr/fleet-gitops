# ApplicationSets

The fleet's templates. [root-app.yaml](../root-app.yaml) syncs this folder; each ApplicationSet here generates Argo CD Applications from the inventory ([clusters/](../clusters/)) and the product declarations ([products/](../products/)). Owned by the platform team.

| File | Kind | Generates |
| --- | --- | --- |
| [fleet-platform-project.yaml](fleet-platform-project.yaml) | AppProject | `fleet-platform`, the project for platform-owned Applications |
| [platform-namespaces-appset.yaml](platform-namespaces-appset.yaml) | ApplicationSet | `<cluster>-platform-namespaces`: shared platform namespaces |
| [platform-helm-addons-appset.yaml](platform-helm-addons-appset.yaml) | ApplicationSet | `<cluster>-<addon>`: cert-manager, ingress-nginx, Argo Rollouts, External Secrets, metrics-server, kube-prometheus-stack, Kyverno |
| [kyverno-policies-appset.yaml](kyverno-policies-appset.yaml) | ApplicationSet | `<cluster>-kyverno-policies`: guardrails, overlay per environment |
| [observability-agents-appset.yaml](observability-agents-appset.yaml) | ApplicationSet | `<cluster>-observability-agent`: Alloy shipping logs to Loki |
| [platform-observability.yaml](platform-observability.yaml) | Applications | `platform-loki`, `platform-grafana` on the hub |
| [product-projects.yaml](product-projects.yaml) | ApplicationSet | `product-<name>-project`: one AppProject per product |
| [product-namespaces.yaml](product-namespaces.yaml) | ApplicationSet | `<product>-<cluster>-baseline`: namespace, quota, limits, network policy, RBAC |
| [product-apps.yaml](product-apps.yaml) | ApplicationSet | `<product>-<cluster>`: the product's workloads |

## Generator patterns

| Pattern | Example | Use |
| --- | --- | --- |
| Git files | [platform-namespaces-appset.yaml](platform-namespaces-appset.yaml) | One Application per `clusters/*.yaml` |
| Matrix: git files × list | [platform-helm-addons-appset.yaml](platform-helm-addons-appset.yaml) | Every add-on on every cluster |
| Nested matrix: (git files × `elementsYaml` list) × clusters | [product-apps.yaml](product-apps.yaml) | Expand each product's `environments`, then pick clusters whose `fleet.gitops/environment` label matches |

The product sets use the **cluster generator** with a label selector, so they target the Argo CD cluster Secrets that Terraform labelled from the inventory. A matrix fails when two children produce the same key with different values, which is why product files keep their fields under `product:` (the cluster generator owns `name` and `metadata`).

## Preview before merge

```bash
python3 scripts/fleet_check.py
```

prints every Application these files generate for the current inventory and products, and fails on duplicates or unknown environments. CI posts the difference against `main` on every pull request.

## Sync order

Sync waves (`argocd.argoproj.io/sync-wave`) document the intended order, but generated Applications are independent: an Application that needs something another one creates (a CRD, a namespace) fails and retries until it is there. `product-apps` and `product-namespaces` set `retry` with backoff for exactly that.
