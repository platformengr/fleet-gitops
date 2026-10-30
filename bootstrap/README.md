# Bootstrap scripts

These scripts build the hub-and-spoke fleet the course uses: one hub cluster running Argo CD, plus a `dev` and a `prod` spoke. Run them from the repository root.

| Track | Up | Down | Hub / spokes | Kube contexts |
| --- | --- | --- | --- | --- |
| kind (local) | `bootstrap/kind/up.sh` | `bootstrap/kind/down.sh` | `platform`, `dev`, `prod` | `kind-platform`, `kind-dev`, `kind-prod` |
| AKS | `bootstrap/aks/up.sh` | `bootstrap/aks/down.sh` | `${PREFIX}-hub/-dev/-prod` | `fleet-hub`, `fleet-dev`, `fleet-prod` |
| EKS | `bootstrap/eks/up.sh` | `bootstrap/eks/down.sh` | `${PREFIX}-hub/-dev/-prod` | `fleet-hub`, `fleet-dev`, `fleet-prod` |
| GKE | `bootstrap/gke/up.sh` | `bootstrap/gke/down.sh` | `${PREFIX}-hub/-dev/-prod` | `fleet-hub`, `fleet-dev`, `fleet-prod` |

Start with `--dry-run`. It prints every command that would change something (and the manifests it would apply, tokens redacted) without running anything, so you can read exactly what a script will do to your account first.

## Before you start: point the repo at your fork

Argo CD reads Git, not your laptop. Fork the repo, then:

```bash
scripts/set-repo-url.sh https://github.com/<you>/fleet-gitops.git
git commit -am "Point Argo CD at my fork" && git push
```

`kind/up.sh` stops if `root-app.yaml` and your `origin` remote don't match (skip the check with `--no-git-check`). The cloud scripts print a warning instead.

## Flags

| Flag | kind/up.sh | cloud up.sh | down.sh |
| --- | --- | --- | --- |
| `--dry-run` | yes | yes | yes |
| `--no-git-check` | yes | n/a (warning only) | n/a |
| `--skip-root-app` | yes | yes | n/a |
| `--profile local\|prod` | yes (default `local`) | yes (default `prod`) | n/a |
| `--env-file FILE` | n/a | yes (default `<cloud>/env`, else `<cloud>/env.example`) | yes |
| `--yes` / `-y` | n/a | n/a | skip the confirmation prompt |

Settings: `cp bootstrap/<cloud>/env.example bootstrap/<cloud>/env`, then edit `env`. It is git-ignored. You can also override any value from the shell, for example `PREFIX=demo REGION=eastus bootstrap/aks/up.sh`.

## What every up.sh does

1. Creates the hub and the two spokes. It skips any cluster that already exists, so you can re-run it.
2. Installs Argo CD on the hub with Helm (`argo/argo-cd`, version pinned in `lib/argocd.sh` as `ARGOCD_CHART_VERSION`; Renovate bumps it). Values come from `argocd/values-local.yaml` or `argocd/values-prod.yaml`.
3. Registers each spoke **declaratively**: on the spoke it creates a ServiceAccount `kube-system/argocd-manager` with RBAC and a token Secret. On the hub it writes a cluster Secret `argocd/cluster-<name>` labelled `argocd.argoproj.io/secret-type: cluster`, `fleet.gitops/environment`, `fleet.gitops/region` and `fleet.gitops/upgrade-wave`.
4. Writes the real API endpoint into `clusters/dev.yaml` and `clusters/prod.yaml`. The inventory format stays the same: `name`, `server`, `environment`, `upgradeWave`, `region`, `lokiEndpoint`.
5. Applies `root-app.yaml`, then prints how to open the UI and what to commit.

**Afterwards, commit and push `clusters/`.** The ApplicationSets read the inventory from Git, so until you push, Argo CD still sees the old endpoints.

## Prerequisites

All tracks need `kubectl`, `helm` (v3) and `git`, plus bash 4+. On macOS, `brew install bash` (the scripts use `#!/usr/bin/env bash`).

| Track | Also needs | Log in with |
| --- | --- | --- |
| kind | Docker (about 8 GB RAM free), `kind` | n/a |
| AKS | `az` CLI | `az login`, then set `AZ_SUBSCRIPTION` or `az account set` |
| EKS | `aws` CLI v2, `eksctl` (recent; needs Pod Identity support) | `aws sso login` / `AWS_PROFILE` |
| GKE | `gcloud`, `gke-gcloud-auth-plugin` | `gcloud auth login`; set `PROJECT_ID` |

Your cloud identity needs rights to create clusters and networking. For AKS that means Contributor on the subscription or resource group. For EKS, eksctl's IAM permissions. For GKE, Kubernetes Engine Admin plus Service Account User.

## What each cloud creates

**AKS** creates one resource group (`${PREFIX}-rg`, tagged `managed-by=fleet-gitops-bootstrap`). Each cluster gets:

- Standard tier, managed identity, OIDC issuer and workload identity
- Azure CNI overlay with the Cilium dataplane, which enforces network policy
- the `stable` auto-upgrade channel and `NodeImage` node OS upgrades
- a tainted `system` pool and an autoscaling `user` pool, spread across zones 1-3

**EKS** gives each cluster its own VPC (eksctl default) with a NAT gateway. Each cluster gets:

- an OIDC provider (IRSA), the EKS Pod Identity agent and the EBS CSI driver (permissions through Pod Identity)
- access entries (`authenticationMode: API`) and control plane logging
- `system` and `workers` managed node groups in private subnets, with encrypted volumes

Rendered configs land in `bootstrap/eks/.generated/`. Node groups have min/max sizes, but nothing scales them until you install Karpenter or Cluster Autoscaler.

**GKE** creates Standard clusters, regional by default or zonal if you set `ZONE`. Each cluster gets:

- Workload Identity Federation (`PROJECT_ID.svc.id.goog`) and `GKE_METADATA` on nodes
- Dataplane V2, which enforces network policy, and VPC-native networking
- the `regular` release channel, shielded nodes (secure boot) and an autoscaling pool

GKE has no separate system pool. Regional node counts are per zone.

The hub needs 3 worker nodes for Argo CD's `redis-ha`. The scripts start the hub's pool at `HUB_NODE_COUNT_MIN=3`. On GKE, a regional cluster gets 3 by default.

## Cost warning

The cloud tracks run **three clusters with production-leaning defaults**: paid control planes (AKS Standard tier, EKS per-cluster fee, GKE cluster fee), several nodes each, NAT gateways and load balancers. That adds up quickly, even overnight. To keep costs down:

- Run `down.sh` when you finish a session.
- For learning, shrink `NODE_SIZE` and the counts. AKS: `AKS_TIER=free`. GKE: set `ZONE` for zonal clusters.
- Set a budget alert in your cloud account before the first run.

kind costs nothing and covers lessons 01-08.

## Security notes

- **Spoke credentials.** Each spoke is registered with a long-lived ServiceAccount token, stored in a Secret on the hub, with cluster-wide rights. It works the same way on every provider, but it is a stepping stone. Lesson 10 replaces it with workload identity, so no static credential exists: `argocd-k8s-auth azure` on AKS, IRSA or Pod Identity with `awsAuthConfig` on EKS, `argocd-k8s-auth gcp` on GKE. The replacement `config` blocks are in the comments of `lib/argocd.sh`. After switching, delete `kube-system/argocd-manager-token` on each spoke.
- **API endpoints are public by default** (authenticated, but reachable from the internet). Restrict them with `API_AUTHORIZED_IP_RANGES` (AKS), `API_PUBLIC_ACCESS_CIDRS` (EKS) or `MASTER_AUTHORIZED_NETWORKS` (GKE). Private clusters work too, as long as the hub can still reach the spokes over private networking (VNet/VPC peering, PrivateLink, Connect Gateway).
- **Argo CD admin.** The initial admin password is for the first login only. Configure SSO and RBAC (lesson 09), set `admin.enabled: "false"`, and delete `argocd-initial-admin-secret`. `values-prod.yaml` already makes read-only the default role.
- **TLS.** `server.insecure` is `false` in both profiles. Expose Argo CD through an ingress or Gateway with a real certificate, preferably on an internal load balancer.
- **Local files.** `bootstrap/*/env` may contain account IDs. It is git-ignored, so keep secrets out of `env.example`.

## Tear down

```bash
bootstrap/kind/down.sh            # deletes kind clusters prod, dev, platform
bootstrap/aks/down.sh             # deletes the 3 clusters, then the resource group if up.sh created it
bootstrap/eks/down.sh             # deletes LoadBalancer Services, then eksctl delete cluster (VPC, NAT, node groups)
bootstrap/gke/down.sh             # deletes the 3 clusters
```

Each one asks for confirmation (`--yes` skips it) and removes the `fleet-*` kube contexts. Afterwards, check for leftovers that can outlive a cluster: persistent disks from PVCs, static IPs, and DNS records.

`clusters/*.yaml` keeps the old endpoints until the next `up.sh`.

## Files

```text
bootstrap/
  lib/common.sh        logging, run (dry-run aware), require_cmd, confirm, wait_for, env + inventory helpers
  lib/argocd.sh        install_argocd_hub, register_spoke, apply_root_app, bootstrap_fleet
  argocd/values-local.yaml   single replicas, small requests, progressive sync on
  argocd/values-prod.yaml    HA: redis-ha, server/repo-server HPA (min 2), 2 ApplicationSet controllers, PDBs, requests/limits
  kind/  aks/  eks/  gke/    up.sh, down.sh, env.example (clouds)
scripts/set-repo-url.sh      point root-app.yaml + applicationsets/ at your fork
```
