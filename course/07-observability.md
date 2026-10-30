# 07 Observability

**Goal:** get logs from every spoke into one Loki/Grafana on the hub, keep metrics per cluster, and understand the cross-cluster network path.
**Time:** 40 minutes

**You'll touch:** [applicationsets/observability-agents-appset.yaml](../applicationsets/observability-agents-appset.yaml), [applicationsets/platform-observability.yaml](../applicationsets/platform-observability.yaml), [clusters/*.yaml](../clusters/) (`lokiEndpoint`), [docs/observability-topology.md](../docs/observability-topology.md), [docs/telemetry-collection.md](../docs/telemetry-collection.md)

## Concepts

```text
  dev spoke                         prod spoke
 +---------------------+           +---------------------+
 | Alloy DaemonSet     |           | Alloy DaemonSet     |
 |  labels: cluster,   |           |  labels: cluster,   |
 |  environment, ns,   |           |  environment, ns,   |
 |  pod, container     |           |  pod, container     |
 | kube-prometheus-    |           | kube-prometheus-    |
 |  stack (local)      |           |  stack (local)      |
 +----------+----------+           +----------+----------+
            |  push logs to lokiEndpoint      |
            +---------------+-----------------+
                            v
              +---------------------------+
              | hub: observability ns     |
              |  Loki (SingleBinary)      |
              |  Grafana (Loki datasource)|
              +---------------------------+
```

- **Logs** are centralized: Alloy on every node reads pod logs and pushes to Loki on the hub. Each cluster's push URL comes from `lokiEndpoint` in its inventory file, so the ApplicationSet template stays the same everywhere.
- **Metrics** stay local in this reference: each cluster gets kube-prometheus-stack with Grafana disabled. Centralizing metrics is a separate decision (remote-write to a central Prometheus-compatible store such as Mimir or Thanos, or a Grafana datasource per cluster).
- **Labels are the fleet.** `cluster` and `environment` on every log line let one query cover the whole fleet or one cluster.

### The catch: reachability

The default `lokiEndpoint` is `http://loki-gateway.observability.svc.cluster.local/...`. That DNS name only resolves **inside the hub**. From a spoke, it points nowhere. Real fleets need a reachable route: private ingress or internal load balancer, VPN/peering, a service mesh, or a managed Loki endpoint. On kind, we'll use a NodePort on the hub's container IP.

## Hands-on

### 1. Check that the pieces are there

```bash
kubectl --context kind-platform -n argocd get applications platform-loki platform-grafana
kubectl --context kind-dev -n observability-agents get daemonset
```

### 2. See the problem

```bash
kubectl --context kind-dev -n observability-agents logs ds/alloy --tail=20 | grep -i -m3 -E 'error|no such host'
```

You'll likely see DNS or connection errors: the spoke can't resolve the hub's service name.

### 3. Give the spokes a route (kind)

Expose the Loki gateway on a NodePort. (In a real fleet this would be a manifest in Git, e.g. an internal LoadBalancer Service; here we create it by hand to keep the lab short.)

```bash
TP=$(kubectl --context kind-platform -n observability get svc loki-gateway -o jsonpath='{.spec.ports[0].targetPort}')
kubectl --context kind-platform -n observability expose svc loki-gateway \
  --name loki-gateway-external --type NodePort --port 80 --target-port "$TP"
NODEPORT=$(kubectl --context kind-platform -n observability get svc loki-gateway-external -o jsonpath='{.spec.ports[0].nodePort}')
HUB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' platform-control-plane)
echo "http://${HUB_IP}:${NODEPORT}/loki/api/v1/push"
```

Put that URL in both inventory files, then push:

```bash
URL="http://${HUB_IP}:${NODEPORT}/loki/api/v1/push"
yq -i ".lokiEndpoint = \"${URL}\"" clusters/dev.yaml
yq -i ".lokiEndpoint = \"${URL}\"" clusters/prod.yaml
git commit -am "observability: reachable Loki endpoint for kind" && git push
```

Refresh `fleet-platform-config`. The `dev-observability-agent` and `prod-observability-agent` apps re-render Alloy's config with the new URL.

### 4. Query the fleet

```bash
# terminal 1
kubectl --context kind-platform -n observability port-forward svc/grafana 3000:80
# terminal 2
kubectl --context kind-platform -n observability get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Open http://localhost:3000 (user `admin`), go to **Explore**, datasource **Loki**, and try:

```logql
{cluster="dev"}
sum by (cluster) (count_over_time({namespace="kube-system"}[5m]))
{environment="prod", namespace="product-a"} |= "error"
```

### 5. Metrics on a spoke

```bash
kubectl --context kind-dev -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Open http://localhost:9090 and run `sum by (namespace) (kube_pod_info)`.

## Check yourself

Ask Loki directly which clusters it has heard from:

```bash
kubectl --context kind-platform -n observability port-forward svc/loki-gateway 3100:80 &
curl -s localhost:3100/loki/api/v1/label/cluster/values | jq -c .data
kill %1
```

```text
["dev","prod"]
```

## Break it on purpose

**1. Make a log line and find it.**

```bash
kubectl --context kind-prod -n product-a run hello-log --image=busybox --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"hello-log","image":"busybox","args":["sh","-c","echo fleet-says-hi; sleep 5"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
```

In Grafana: `{cluster="prod"} |= "fleet-says-hi"`. (The overrides satisfy the `restricted` Pod Security level from module 06. Good reminder of why it exists.)

**2. Cut the route.** `kubectl --context kind-platform -n observability delete svc loki-gateway-external`. Watch Alloy's logs on dev fill with connection errors, and watch new dev lines stop arriving. Recreate it with the same nodePort (`--overrides` or edit) or update the inventory again. This is what an expired firewall rule looks like in real life.

## Field notes

- In the workshop, the cluster-local `lokiEndpoint` tripped up nearly everyone exactly once. That's why it's an inventory field: the "how do spokes reach the hub" decision is per cluster and per network, not per chart.
- Put the `cluster` label on everything at the edge (the agent), not in queries. You can't add it back to old data.
- Watch Loki label cardinality. `pod` is already high-cardinality; don't add request IDs or user IDs as labels.

## Quiz

1. Why is `lokiEndpoint` in `clusters/*.yaml` instead of hard-coded in the Alloy config?
2. Why doesn't `loki-gateway.observability.svc.cluster.local` work from a spoke?
3. Name two ways to centralize metrics.

<details>
<summary>Answers</summary>

1. The route from each spoke to the hub depends on that spoke's network; the inventory is where per-cluster facts live, and the template stays identical.
2. `svc.cluster.local` names are resolved by the cluster's own DNS; a spoke's DNS doesn't know the hub's services.
3. Remote-write from each Prometheus to a central store (Mimir, Thanos receive, a managed service); or keep Prometheus local and add one Grafana datasource per cluster (or federate).

</details>

**Next:** [08 Progressive delivery](08-progressive-delivery.md)
