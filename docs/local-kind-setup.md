# Local Kind Setup

This page expands the quick setup in [../README.md](../README.md). It is meant for a local learning environment, not a production install.

## What You Will Build

```text
kind-platform  -> Argo CD, platform Loki, platform Grafana
kind-dev       -> workload cluster generated from clusters/dev.yaml
kind-prod      -> workload cluster generated from clusters/prod.yaml
```

Argo CD must know the same cluster API server URLs that appear in [../clusters/dev.yaml](../clusters/dev.yaml) and [../clusters/prod.yaml](../clusters/prod.yaml). That match is important because the ApplicationSets use `destination.server`.

## Prerequisites

- Docker
- `kind`
- `kubectl`
- `argocd`
- `git`
- `perl`

## 1. Create The Clusters

```bash
kind create cluster --name platform
kind create cluster --name dev
kind create cluster --name prod
```

## 2. Install Argo CD On The Platform Cluster

```bash
kubectl --context kind-platform create namespace argocd
kubectl --context kind-platform apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl --context kind-platform -n argocd rollout status deploy/argocd-server
kubectl --context kind-platform -n argocd rollout status deploy/argocd-repo-server
kubectl --context kind-platform -n argocd rollout status deploy/argocd-applicationset-controller
kubectl --context kind-platform -n argocd rollout status statefulset/argocd-application-controller
```

## 3. Point The Repo At Your Git Remote

Argo CD reads from Git. If you are using a fork, replace the sample repo URL in [../root-app.yaml](../root-app.yaml) and [../applicationsets/](../applicationsets/), then push the change.

From the repository root:

```bash
export REPO_URL="https://github.com/YOUR_ORG/fleet-gitops.git"
perl -pi -e "s#https://github.com/platformengr/fleet-gitops.git#$REPO_URL#g" root-app.yaml applicationsets/*.yaml
git add root-app.yaml applicationsets
git commit -m "Point Argo CD at my repo"
git push
```

## 4. Update Cluster Inventory For Kind

The sample [../clusters/dev.yaml](../clusters/dev.yaml) and [../clusters/prod.yaml](../clusters/prod.yaml) show local kind-style API server addresses. Your container IPs may be different.

From the repository root:

```bash
DEV_API="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dev-control-plane)"
PROD_API="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' prod-control-plane)"

sed -i "s#^server:.*#server: https://${DEV_API}:6443#" clusters/dev.yaml
sed -i "s#^server:.*#server: https://${PROD_API}:6443#" clusters/prod.yaml

git add clusters/dev.yaml clusters/prod.yaml
git commit -m "Use local kind cluster endpoints"
git push
```

## 5. Log In To Argo CD

Keep this command running in one terminal:

```bash
kubectl --context kind-platform -n argocd port-forward svc/argocd-server 8080:443
```

In another terminal:

```bash
ARGOCD_PASSWORD="$(kubectl --context kind-platform -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
argocd login localhost:8080 --username admin --password "$ARGOCD_PASSWORD" --insecure
```

## 6. Register The Workload Clusters

Use temporary kubeconfigs so your normal kubeconfig is not rewritten.

```bash
kind get kubeconfig --name dev > /tmp/kind-dev.kubeconfig
kind get kubeconfig --name prod > /tmp/kind-prod.kubeconfig
DEV_API="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dev-control-plane)"
PROD_API="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' prod-control-plane)"

kubectl --kubeconfig /tmp/kind-dev.kubeconfig config set-cluster kind-dev --server="https://${DEV_API}:6443"
kubectl --kubeconfig /tmp/kind-prod.kubeconfig config set-cluster kind-prod --server="https://${PROD_API}:6443"

KUBECONFIG=/tmp/kind-dev.kubeconfig argocd cluster add kind-dev --name dev --yes
KUBECONFIG=/tmp/kind-prod.kubeconfig argocd cluster add kind-prod --name prod --yes
```

## 7. Bootstrap The Fleet

From the repository root:

```bash
kubectl --context kind-platform apply -f root-app.yaml
kubectl --context kind-platform -n argocd get applicationsets
kubectl --context kind-platform -n argocd get applications
```

## What To Check

```bash
kubectl --context kind-platform -n argocd get app
kubectl --context kind-dev get ns
kubectl --context kind-prod get ns
kubectl --context kind-dev get ns product-a --show-labels
kubectl --context kind-prod get resourcequota,limitrange,networkpolicy -n product-a
```

## Common Local Issues

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Applications show an unknown cluster | The `server` in [../clusters/](../clusters/) does not match the Argo CD cluster registration. | Update the cluster file, push it, and re-register the cluster with the same URL. |
| Argo CD keeps reading old manifests | The change is local but not pushed to the repo URL Argo CD reads. | Commit and push, or change repo URLs to a Git remote Argo CD can access. |
| Loki endpoint cannot be reached from workload clusters | The sample endpoint uses cluster-local DNS. | For real separate clusters, expose Loki through an internal ingress, private load balancer, service mesh, VPN, or another reachable route. |
| Kind cluster was recreated | The control-plane container IP changed. | Repeat the inventory update and cluster registration steps. |

## Cleanup

```bash
kind delete cluster --name prod
kind delete cluster --name dev
kind delete cluster --name platform
rm -f /tmp/kind-dev.kubeconfig /tmp/kind-prod.kubeconfig
```