# product-namespace chart

The platform-owned baseline for one product in one environment on one cluster.
Rendered by [applicationsets/product-namespaces.yaml](../../applicationsets/product-namespaces.yaml)
from [products/*/product.yaml](../../products/).

| Object | Why |
| --- | --- |
| `Namespace` | Ownership, environment and cost-center labels; Pod Security Standard labels; `Prune=false` so offboarding never deletes data by accident |
| `ResourceQuota`, `LimitRange` | Size profile (`small`/`medium`/`large`) from the product's environment entry |
| `NetworkPolicy` x3 | Default deny ingress; allow same namespace and the ingress controller |
| `RoleBinding` | The owning team gets `edit` in its namespace, nothing else |
| `SecretStore` | Optional, off by default (course module 10) |

Every object carries `fleet.gitops/managed-by: platform`. The Kyverno policy
`protect-platform-baseline` rejects changes to those objects from anyone but
the platform (Argo CD, cluster admins), so a product team cannot raise its own
quota or remove the default-deny policy with `kubectl`.

Render it locally:

```bash
# product.yaml's top-level `product:` block is exactly the chart's `product` value
helm template checkout charts/product-namespace \
  -f products/checkout/product.yaml --set environment=prod --set size=medium
```
