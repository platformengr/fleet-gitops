# Observability Topology

This page shows where observability components run in the fleet.

The short version: Grafana and Loki run on the management cluster. Workload clusters run local collectors and metrics components.

## Topology

```text
dev cluster  -> Alloy logs -> platform Loki -> platform Grafana
prod cluster -> Alloy logs -> platform Loki -> platform Grafana

dev cluster  -> local kube-prometheus-stack
prod cluster -> local kube-prometheus-stack
```

## Management Cluster

[../applicationsets/platform-observability.yaml](../applicationsets/platform-observability.yaml) creates two Argo CD Applications that target the Argo CD management cluster:

```yaml
destination:
  server: https://kubernetes.default.svc
  namespace: observability
```

Those Applications install:

| Application | Component | Purpose |
| --- | --- | --- |
| `platform-loki` | Loki | Central log store for the reference environment. |
| `platform-grafana` | Grafana | Central UI with a preconfigured Loki datasource. |

Because the destination server is `https://kubernetes.default.svc`, these components are not generated once per workload cluster.

## Workload Clusters

Workload clusters come from [../clusters/dev.yaml](../clusters/dev.yaml) and [../clusters/prod.yaml](../clusters/prod.yaml).

They receive two observability layers:

| Layer | Defined in | What it does |
| --- | --- | --- |
| kube-prometheus-stack | [../applicationsets/platform-helm-addons-appset.yaml](../applicationsets/platform-helm-addons-appset.yaml) | Runs local Prometheus and Alertmanager components. |
| Grafana Alloy | [../applicationsets/observability-agents-appset.yaml](../applicationsets/observability-agents-appset.yaml) | Runs as a DaemonSet and ships pod logs to Loki. |

The workload cluster kube-prometheus-stack disables Grafana:

```yaml
grafana:
  enabled: false
```

That keeps dashboard access centralized instead of creating separate Grafana instances in `dev` and `prod`.

## Endpoint Caveat

Each cluster inventory file has a `lokiEndpoint` value. A spoke cannot resolve the hub's `*.svc.cluster.local` names, so the Loki gateway on the hub is exposed declaratively (a fixed NodePort in [platform-observability.yaml](../applicationsets/platform-observability.yaml)) and the kind spokes push to the hub node by its Docker network name:

```yaml
lokiEndpoint: http://platform-control-plane:31100/loki/api/v1/push
```

On real networks, replace the NodePort with an endpoint reachable from workload clusters, such as an internal load balancer, private ingress, service mesh, VPN, or a managed Loki endpoint, and put its URL in the inventory.

## Where To Go Next

| Topic | Link |
| --- | --- |
| Log and metric collection details | [telemetry-collection.md](telemetry-collection.md) |
| Platform add-on inventory | [../addons/README.md](../addons/README.md) |
| Cluster inventory fields | [../clusters/dev.yaml](../clusters/dev.yaml), [../clusters/prod.yaml](../clusters/prod.yaml) |

## Future Extension

For a larger fleet, add central metrics storage such as Mimir and remote-write from workload clusters. The current topology can grow in that direction without moving Grafana out of the management cluster.