# 03 Fleet inventory

**Goal:** turn one cluster into a hub, register `dev` and `prod` spokes, and describe them in a Git inventory that generators can read.
**Time:** 45 minutes

**You'll touch:** [clusters/dev.yaml](../clusters/dev.yaml), [clusters/prod.yaml](../clusters/prod.yaml), [clusters/README.md](../clusters/README.md), [root-app.yaml](../root-app.yaml), [docs/fleet-architecture.md](../docs/fleet-architecture.md)

## Concepts

### Hub and spoke

```text
              +-------------------------------+
              | hub: kind-platform            |
              |  argocd ns                    |
              |   - cluster Secret "dev"  ----+-----> https://<dev-api>:6443
              |   - cluster Secret "prod" ----+-----> https://<prod-api>:6443
              +-------------------------------+
```

One Argo CD (on the hub) manages many clusters. Spokes run no Argo CD; they only need to accept API calls from the hub. Pros: one place to look, one upgrade, one RBAC model. Cons: the hub is important (module 11 makes it HA), and the hub needs network reach to every spoke API (module 10 covers private endpoints).

The alternative, an Argo CD per cluster, is simpler for isolation but you lose the fleet view. For most SMEs I'd start with hub-and-spoke.

### Two things describe a spoke

| | Where | Contains | Who reads it |
| --- | --- | --- | --- |
| **Cluster Secret** | `argocd` namespace on the hub, label `argocd.argoproj.io/secret-type: cluster` | `name`, `server`, credentials `config` | Argo CD, to connect |
| **Inventory file** | `clusters/<name>.yaml` in Git | `name`, `server`, `environment`, `upgradeWave`, `region`, `lokiEndpoint` | ApplicationSet Git files generator, to decide *what* goes *where* |

```yaml
# clusters/dev.yaml
name: dev
server: https://172.18.0.3:6443   # must equal the cluster Secret's server
environment: dev                  # picks overlays/dev
upgradeWave: "0"                  # rollout order (module 08)
region: local
lokiEndpoint: http://loki-gateway.observability.svc.cluster.local/loki/api/v1/push
```

Credentials never go in Git; facts about the cluster do. The `server` field is the join key between the two.

> There is also a **cluster generator** that reads the cluster Secrets (and their labels) directly. This repo uses Git files so the inventory is reviewable in PRs and carries extra fields. Both are valid; module 04 compares them.

## Hands-on

### Shortcut

```bash
REPO_URL="$REPO_URL" ./bootstrap/kind/up.sh
```

It creates `platform`, `dev` and `prod`, installs Argo CD on the hub, registers the spokes as declarative Secrets, updates `clusters/*.yaml` with the right servers and applies `root-app.yaml`. Commit and push the changed inventory files when it tells you to. Then skip to [Check yourself](#check-yourself), or keep reading to learn what it did.

### Manual

**1. Create the spokes** (the hub from module 01 is already there):

```bash
kind create cluster --name dev
kind create cluster --name prod
```

**2. Find addresses the hub can reach.** kind clusters share the `kind` Docker network, so the hub reaches the spokes on their container IPs, not on `127.0.0.1:<port>` from your kubeconfig.

```bash
DEV_API="https://$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dev-control-plane):6443"
PROD_API="https://$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' prod-control-plane):6443"
echo "$DEV_API $PROD_API"
```

**3a. Register with the CLI** (quick, imperative):

```bash
kind get kubeconfig --name dev > /tmp/kind-dev.kubeconfig
kubectl --kubeconfig /tmp/kind-dev.kubeconfig config set-cluster kind-dev --server="$DEV_API"
KUBECONFIG=/tmp/kind-dev.kubeconfig argocd cluster add kind-dev --name dev --yes
```

`argocd cluster add` creates an `argocd-manager` ServiceAccount with cluster-admin on the spoke and stores its token in a cluster Secret on the hub.

**3b. Register declaratively** (what the bootstrap script does, and what you want long-term). Do it for `prod`:

```bash
# on the spoke: a ServiceAccount + long-lived token (kind only; module 10 removes this)
kubectl --context kind-prod -n kube-system create serviceaccount argocd-manager
kubectl --context kind-prod create clusterrolebinding argocd-manager \
  --clusterrole=cluster-admin --serviceaccount=kube-system:argocd-manager
kubectl --context kind-prod -n kube-system apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF

TOKEN=$(kubectl --context kind-prod -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl --context kind-prod -n kube-system get secret argocd-manager-token -o jsonpath='{.data.ca\.crt}')

# on the hub: the cluster Secret
kubectl --context kind-platform -n argocd apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-prod
  labels:
    argocd.argoproj.io/secret-type: cluster
    fleet.gitops/environment: prod
type: Opaque
stringData:
  name: prod
  server: ${PROD_API}
  config: |
    {"bearerToken": "${TOKEN}", "tlsClientConfig": {"caData": "${CA}"}}
EOF
```

The label `argocd.argoproj.io/secret-type: cluster` is what makes Argo CD treat the Secret as a cluster. Extra labels (`fleet.gitops/environment`) are for cluster generators and humans. See the [declarative setup docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters).

**4. Update the inventory** so `server` matches:

```bash
sed -i "s#^server:.*#server: ${DEV_API}#"  clusters/dev.yaml
sed -i "s#^server:.*#server: ${PROD_API}#" clusters/prod.yaml
git commit -am "inventory: local kind endpoints" && git push
```

**5. Bootstrap the fleet.** Remove the lab apps from module 02 if you like (`kubectl -n argocd delete app lab-root`), then:

```bash
kubectl --context kind-platform apply -f root-app.yaml
```

## Check yourself

```bash
argocd cluster list
```

```text
SERVER                          NAME        VERSION  STATUS      MESSAGE
https://172.18.0.4:6443         prod        1.3x     Successful
https://172.18.0.3:6443         dev         1.3x     Successful
https://kubernetes.default.svc  in-cluster           ...
```

(`STATUS` can read `Unknown` until an app is deployed to that cluster. That's normal.)

```bash
kubectl --context kind-platform -n argocd get secret -l argocd.argoproj.io/secret-type=cluster
kubectl --context kind-platform -n argocd get applications | grep -E '^(dev|prod)-' | head
```

You should see two cluster Secrets and applications named `dev-...` and `prod-...`.

## Break it on purpose

**1. Wrong server in the inventory.** In a branch, change the last octet of `server` in `clusters/prod.yaml`, push it to `main` of your fork (it's a lab), refresh `fleet-platform-config`:

```bash
argocd app get prod-guestbook --refresh | grep -i -A2 condition
```

The generated apps report that the destination cluster isn't configured. The Git inventory and the cluster Secrets must agree. Revert.

**2. Remove a spoke from the inventory.** In a branch, `git rm clusters/prod.yaml` and look at what would happen:

```bash
git diff main --stat
```

Every `prod-*` Application would disappear from every ApplicationSet at once, and with `prune` that can mean uninstalling things on prod. Don't merge it. This is why `clusters/` is in [CODEOWNERS](../.github/CODEOWNERS).

## Field notes

- In the workshop, the second most common snag was registering spokes with `127.0.0.1:<port>`. That address is only right from your laptop. From inside the hub it points at the hub itself.
- Name clusters after their role (`dev`, `prod-eu`), not their provider ID. Names show up in every generated app name and are painful to change later.
- Treat `clusters/*.yaml` like a database schema: decide your fields early, add new ones with defaults, and validate them in CI (module 11).

## Quiz

1. What field joins `clusters/prod.yaml` to its Argo CD cluster Secret?
2. Why do the kind spokes use container IPs instead of the `127.0.0.1` address from kubeconfig?
3. What's wrong with the bearer-token approach in production?

<details>
<summary>Answers</summary>

1. `server`. The ApplicationSet uses it as `destination.server`, and Argo CD looks up the cluster Secret with the same server.
2. The hub runs in its own container; `127.0.0.1` there is the hub, not the spoke. Containers on the `kind` network reach each other by IP.
3. It's a long-lived, cluster-admin credential stored in a Secret. If it leaks, it works until someone rotates it. Module 10 replaces it with cloud workload identity and short-lived tokens.

</details>

**Next:** [04 ApplicationSets](04-applicationsets.md)
