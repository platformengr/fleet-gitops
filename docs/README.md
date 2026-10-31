# Documentation Map

Use this directory when you want the architecture before reading every manifest. Each page is short on purpose: what the concept is, how this repo uses it, and which files matter.

## Start Here

| Page | Use it for |
| --- | --- |
| [../README.md](../README.md) | What this repo is and how to use it. The guided course lives at https://www.platformengr.com/learn/fleet-gitops/. |
| [fleet-architecture.md](fleet-architecture.md) | The platform/workload split, sync order, and data flow. |
| [local-kind-setup.md](local-kind-setup.md) | A more careful local multi-cluster setup. |
| [../clusters/README.md](../clusters/README.md) | The cluster inventory contract. |
| [../applicationsets/README.md](../applicationsets/README.md) | How ApplicationSets generate Applications. |
| [kustomize-overlays.md](kustomize-overlays.md) | What the `kustomization.yaml` files do here. |
| [tenant-namespace-flow.md](tenant-namespace-flow.md) | How a namespace request becomes a real Namespace and policies. |
| [observability-topology.md](observability-topology.md) | What runs on the platform cluster versus workload clusters. |
| [telemetry-collection.md](telemetry-collection.md) | How logs and metrics are collected. |

## Folder References

| Folder | README |
| --- | --- |
| Application generation | [../applicationsets/README.md](../applicationsets/README.md) |
| Cluster inventory | [../clusters/README.md](../clusters/README.md) |
| Platform add-ons | [../addons/README.md](../addons/README.md) |
| Platform namespaces | [../addons/namespaces/README.md](../addons/namespaces/README.md) |
| Kyverno policies | [../addons/kyverno-policies/README.md](../addons/kyverno-policies/README.md) |
| Tenant namespace chart | [../charts/tenant-namespace/README.md](../charts/tenant-namespace/README.md) |
| Namespace requests | [../requests/namespaces/README.md](../requests/namespaces/README.md) |
| Sample workloads | [../examples/README.md](../examples/README.md) |

## Suggested Reading Time

For a quick tour, read [fleet-architecture.md](fleet-architecture.md), [../applicationsets/README.md](../applicationsets/README.md), and [tenant-namespace-flow.md](tenant-namespace-flow.md). That covers the main ideas without getting stuck in Helm chart values.