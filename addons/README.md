# Platform Add-ons

This directory contains the platform layer: namespaces, controllers, policy packages, and observability components that support workloads on every cluster.

Read this page when you want to know what the platform installs before product workloads arrive.

## How It Works Here

The repo uses two patterns for add-ons:

| Pattern | Used for | Main files |
| --- | --- | --- |
| Kustomize overlays | Plain Kubernetes YAML that needs a small per-environment difference. | [namespaces/](namespaces/), [kyverno-policies/](kyverno-policies/) |
| Helm charts | Third-party controllers and services with versioned chart releases. | [../applicationsets/platform-helm-addons-appset.yaml](../applicationsets/platform-helm-addons-appset.yaml), [../applicationsets/platform-observability.yaml](../applicationsets/platform-observability.yaml), [../applicationsets/observability-agents-appset.yaml](../applicationsets/observability-agents-appset.yaml) |

Kustomize is used in the simple way: a `base` contains shared resources, and each `overlays/<environment>` folder includes the base and adds environment-specific labels or resources. For example, [namespaces/overlays/dev/kustomization.yaml](namespaces/overlays/dev/kustomization.yaml) includes [namespaces/base/kustomization.yaml](namespaces/base/kustomization.yaml) and adds `environment: dev`.

## Add-on Inventory

| Add-on | Purpose | Where it is defined |
| --- | --- | --- |
| Platform namespaces | Creates namespaces such as `observability`, `ingress-system`, `cert-manager`, and `kyverno`. | [namespaces/README.md](namespaces/README.md), [../applicationsets/platform-namespaces-appset.yaml](../applicationsets/platform-namespaces-appset.yaml) |
| cert-manager | Manages certificate lifecycle and CRDs. | [../applicationsets/platform-helm-addons-appset.yaml](../applicationsets/platform-helm-addons-appset.yaml) |
| ingress-nginx | Provides an ingress controller for HTTP and HTTPS traffic. | [../applicationsets/platform-helm-addons-appset.yaml](../applicationsets/platform-helm-addons-appset.yaml) |
| Argo Rollouts | Installs the Rollout CRD and controller for canary releases (course module 07). | [../applicationsets/platform-helm-addons-appset.yaml](../applicationsets/platform-helm-addons-appset.yaml) |
| external-secrets | Syncs Kubernetes Secrets from external secret stores. | [../applicationsets/platform-helm-addons-appset.yaml](../applicationsets/platform-helm-addons-appset.yaml) |
| metrics-server | Provides Kubernetes resource metrics for `kubectl top` and autoscaling inputs. | [../applicationsets/platform-helm-addons-appset.yaml](../applicationsets/platform-helm-addons-appset.yaml) |
| kube-prometheus-stack | Runs per-cluster Prometheus and Alertmanager. Grafana is disabled here. | [../applicationsets/platform-helm-addons-appset.yaml](../applicationsets/platform-helm-addons-appset.yaml) |
| Kyverno | Installs the policy engine. | [../applicationsets/platform-helm-addons-appset.yaml](../applicationsets/platform-helm-addons-appset.yaml) |
| Kyverno policies | Guardrails between platform and product teams: protected baseline, pinned images, requests and limits. | [kyverno-policies/README.md](kyverno-policies/README.md), [../applicationsets/kyverno-policies-appset.yaml](../applicationsets/kyverno-policies-appset.yaml) |
| Grafana Alloy | Runs as a per-cluster log collection agent. | [../applicationsets/observability-agents-appset.yaml](../applicationsets/observability-agents-appset.yaml), [../docs/telemetry-collection.md](../docs/telemetry-collection.md) |
| Loki and Grafana | Run only on the management cluster as the central reference observability stack. | [../applicationsets/platform-observability.yaml](../applicationsets/platform-observability.yaml), [../docs/observability-topology.md](../docs/observability-topology.md) |

## Fleet Generation

[../applicationsets/platform-helm-addons-appset.yaml](../applicationsets/platform-helm-addons-appset.yaml) uses a matrix generator:

- One side reads every file in [../clusters/](../clusters/).
- The other side lists Helm add-ons and chart versions.
- Argo CD creates one Application per cluster and add-on.

That is the core fleet pattern: add or remove a cluster file, and the generated platform surface changes with it.

## Safe Change Points

| Task | Edit | Watch for |
| --- | --- | --- |
| Add a platform namespace | [namespaces/base/platform-namespaces.yaml](namespaces/base/platform-namespaces.yaml) | Namespace names are cluster-scoped and should not conflict with product namespace names. |
| Add a Helm add-on | The `elements` list in [../applicationsets/platform-helm-addons-appset.yaml](../applicationsets/platform-helm-addons-appset.yaml) | Pin the chart version, set the namespace, and decide whether CRDs or `ServerSideApply=true` are needed. |
| Change environment policy | The relevant overlay under [kyverno-policies/overlays/](kyverno-policies/overlays/) | Confirm the generated resources match the product namespace labels. |
| Change observability | [../applicationsets/platform-observability.yaml](../applicationsets/platform-observability.yaml) or [../applicationsets/observability-agents-appset.yaml](../applicationsets/observability-agents-appset.yaml) | Workload clusters must be able to reach the Loki endpoint in their cluster inventory file. |

## Production Notes

The chart versions are pinned for repeatable learning. For production, review chart values, RBAC, resource requests, CRD upgrades, network exposure, and rollback behavior before enabling automated sync.