# Fleet GitOps

**A reference implementation of a small fleet GitOps platform: how a platform team runs clusters with Terraform and Argo CD, and how product teams onboard and ship through pull requests.**

It is the finished state of the free [Fleet GitOps course](https://www.platformengr.com/learn/fleet-gitops/) by [PlatformEngr](https://www.platformengr.com/), written by [Daniel Abrahamberg](https://www.abrahamberg.com/). Everything runs on your laptop with kind; the same repo runs on AKS, EKS, GKE or any existing cluster.

```text
 Issue ──> pull request ──> CI: validate + fleet plan ──> review (+ production approval) ──> merge
                                                                                          │
   ┌──────────────────────────────────────────────────────────────────────────────────────┘
   v
 Git (this repo) ──pull──> Argo CD on the hub ──> dev cluster ──> checkout-dev   (healthy)
                                              └─> prod cluster ─> checkout-prod  (healthy)
```

## Four things, and how they relate

| | What it is | Where |
| --- | --- | --- |
| **Reference repo** | This repo: the completed implementation. Read it, compare with it, copy folders from it. | `github.com/platformengr/fleet-gitops` |
| **Your repo** | The repo *you* operate. Argo CD watches it, so it must be yours. | Created from this one (template) or built up folder by folder in the course |
| **Quick start** | 30 minutes: create your repo from this template, `terraform apply`, onboard a product, see it run. | [platformengr.com/learn/fleet-gitops/quickstart.html](https://www.platformengr.com/learn/fleet-gitops/quickstart.html) |
| **Full course** | 13 modules that build every piece in order, as platform team and as product team, through issues and pull requests. | [platformengr.com/learn/fleet-gitops/](https://www.platformengr.com/learn/fleet-gitops/) |

There is no separate download: the Terraform and the cloud scripts live in [infrastructure/](infrastructure/) in this repo.

## Quick start (kind)

Needs Docker, [kind](https://kind.sigs.k8s.io/), kubectl, Terraform ≥ 1.6 and Python 3.

1. On GitHub: **Use this template → Create a new repository** (public, so Argo CD can read it without credentials). Clone it.
2. Point the fleet at your repo, check it, push:
   ```bash
   scripts/set-repo-url.sh https://github.com/<you>/<repo>.git --codeowners @<you>
   scripts/validate.sh        # optional locally, CI runs it on every PR
   git commit -am "Point the fleet at my repo" && git push
   ```
3. Create the clusters and hand them to Git:
   ```bash
   cd infrastructure/kind && terraform init && terraform apply
   kubectl --context kind-platform -n argocd get applications -w
   ```
4. Open the Argo CD UI with the commands `terraform output next_steps` prints. Within a few minutes `checkout-dev` and `checkout-prod` are Synced and Healthy.

The course page personalises every command with your GitHub user and repo name.

## How the repo is organised

Folders map to owners. In a larger organisation the three groups are three repositories (`infrastructure-live`, `platform-fleet`, `<product>-deployment`); here they are folders, so the workshop needs one repo, and [CODEOWNERS](.github/CODEOWNERS) keeps the boundaries.

| Folder | Owner | What it holds |
| --- | --- | --- |
| [infrastructure/](infrastructure/) | Platform | Terraform: clusters, Argo CD install, cluster registration, root app. Cloud scripts. |
| [clusters/](clusters/) | Platform | The fleet inventory: one file per workload cluster. Drives Terraform and the ApplicationSets. |
| [root-app.yaml](root-app.yaml), [applicationsets/](applicationsets/) | Platform | What Argo CD generates for every cluster and every product. |
| [addons/](addons/), [charts/](charts/) | Platform | Add-ons, Kyverno guardrails, the namespace baseline chart. |
| [products/](products/) | Product proposes, platform approves | One `product.yaml` per product: the self-service onboarding request. |
| [product-deployments/](product-deployments/) | Product team | Kustomize config per product and environment. |
| [.github/](.github/) | Platform | Issue forms, PR template, CI, production gate, deployment records. |
| [scripts/](scripts/) | Platform | `validate.sh`, `fleet_check.py`, `set-repo-url.sh`, `trace.sh`. |
| [docs/](docs/) | Platform | Architecture, operating model, runbooks. |

## The bootstrap chain

```text
clusters/*.yaml ──> terraform apply (infrastructure/kind)
                      ├─ kind clusters: platform (hub), dev, prod
                      ├─ Argo CD on the hub (Helm)
                      ├─ cluster Secrets, labelled from the inventory
                      └─ root Application (root-app.yaml)
                              └─> applicationsets/  (Argo CD, from Git, forever after)
                                    ├─ per cluster:  namespaces, Helm add-ons, Kyverno policies, log agent
                                    ├─ hub:          Loki + Grafana
                                    └─ per product:  AppProject, namespace baseline per env, app per env
```

Terraform runs once per cluster change; after that every change is a pull request. See [infrastructure/README.md](infrastructure/README.md).

## Product onboarding in one file

```yaml
# products/checkout/product.yaml
apiVersion: platform.platformengr.io/v1alpha1
kind: Product
product:
  name: checkout
  owner: team-checkout
  costCenter: cc-4711
  repository: https://github.com/platformengr/fleet-gitops.git
  path: product-deployments/checkout
  environments:
    - environment: dev
      size: small
    - environment: prod
      size: medium
```

Merging it produces the `checkout` AppProject, a namespace baseline (quota, limits, network policies, RBAC, Pod Security and ownership/cost labels) on every dev and prod cluster, and the Applications `checkout-dev` and `checkout-prod`. See [products/README.md](products/README.md) and [docs/product-onboarding.md](docs/product-onboarding.md).

## What every pull request gets

| Check | What it catches |
| --- | --- |
| `validate` ([scripts/validate.sh](scripts/validate.sh)) | YAML syntax, product schema, unknown environments, missing config folders, missing CODEOWNERS, duplicate Application names, Kubernetes schemas, Helm/Kustomize rendering, Kyverno policy violations, Terraform fmt/validate, shellcheck |
| `plan` | A comment listing the Argo CD Applications the change adds, removes or re-targets |
| `production-gate` | Waits for an approval on the `production` environment when the change reaches prod |
| `deployment-record` (after merge) | A GitHub deployment per product environment, linked to the PR and issue: the changelog |

Then `scripts/trace.sh <commit>` shows when Argo CD has reconciled that commit on every cluster. The whole flow is in [docs/operating-model.md](docs/operating-model.md).

## What is simplified, and what production looks like

| Workshop | Production |
| --- | --- |
| One repo with three owner folders | Separate infrastructure, platform and product repos |
| Terraform state on your laptop, applied by hand | Remote state, `plan` on the PR, `apply` from CI after approval |
| Argo CD reaches kind spokes with the admin certificate | A scoped identity per spoke: workload identity on AKS/EKS/GKE ([infrastructure/cloud/](infrastructure/cloud/)) |
| `team-checkout` is a name; on kind you impersonate it | A group from your identity provider (OIDC/SSO) |
| Deployment records say "merged" | Argo CD Notifications sets the status when the sync finishes |
| Argo CD admin password | SSO and RBAC (course module 10) |

The full list is in [docs/fleet-architecture.md](docs/fleet-architecture.md#production-checklist).

## About

Maintained by [PlatformEngr](https://www.platformengr.com/), which helps growing teams build and run internal platforms, with [Daniel Abrahamberg](https://www.abrahamberg.com/) ([LinkedIn](https://www.linkedin.com/in/abrahamberg/)). Issues and pull requests are welcome.
