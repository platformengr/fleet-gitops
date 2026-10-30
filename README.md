# Fleet GitOps

**A hands-on course and reference repo for running a fleet of Kubernetes clusters with GitOps.** You start with one Argo CD Application on a laptop cluster. You finish with a production-shaped hub-and-spoke fleet on kind, AKS, EKS or GKE: add-ons, tenant guardrails, observability, progressive delivery, secrets and identity.

> This started as a hands-on workshop I ran for [PlatformEngr](https://www.platformengr.com/). Attendees kept asking for the material afterwards, so I cleaned it up and made it public. I hope it saves you some of the hours it cost us. — [Daniel Abrahamberg](https://www.abrahamberg.com/)

## Three ways in

| You want to... | Go here |
| --- | --- |
| **Learn it step by step**, with progress tracking, quizzes and a fleet map that grows as you go | The interactive workshop: [`site/index.html`](site/index.html) (published at `https://abrahamberg.github.io/fleet-gitops/` once Pages is on) |
| **Read the course** in Markdown, module by module | [`course/`](course/README.md) |
| **Just get a fleet running** with a few commands | The quickstart generator: [`site/quickstart.html`](site/quickstart.html), or [`bootstrap/`](bootstrap/README.md) directly |

## The course at a glance

| Level | Modules | You leave with |
| --- | --- | --- |
| 1 Foundations | [00 Welcome](course/00-welcome.md) · [01 GitOps in one cluster](course/01-gitops-in-one-cluster.md) · [02 App of apps](course/02-app-of-apps.md) | Argo CD reconciling Git, drift that heals itself, one root app for everything |
| 2 Fleet | [03 Fleet inventory](course/03-fleet-inventory.md) · [04 ApplicationSets](course/04-applicationsets.md) · [05 Add-ons and sync waves](course/05-addons-and-sync-waves.md) | A hub managing `dev` and `prod` from `clusters/*.yaml`, with the same add-ons everywhere |
| 3 Platform | [06 Tenants and guardrails](course/06-tenants-and-guardrails.md) · [07 Observability](course/07-observability.md) · [08 Progressive delivery](course/08-progressive-delivery.md) | Self-service namespaces by PR, central logs, changes that roll dev-then-prod |
| 4 Production | [09 Secrets and identity](course/09-secrets-and-identity.md) · [10 Going to cloud](course/10-going-to-cloud.md) · [11 Production checklist](course/11-production-checklist.md) | No long-lived credentials, HA Argo CD, CI validation, a day-2 runbook |

My advice: do levels 1 to 3 on kind even if you'll end up in a cloud. Mistakes are free there.

## Quick start (kind)

Prerequisites: Docker, `kind`, `kubectl`, `helm`, `git`.

```bash
# Fork this repo first: Argo CD reads Git, not your laptop.
git clone https://github.com/<you>/fleet-gitops.git && cd fleet-gitops
scripts/set-repo-url.sh https://github.com/<you>/fleet-gitops.git
git commit -am "Point Argo CD at my fork" && git push

bootstrap/kind/up.sh --dry-run   # read what it will do
bootstrap/kind/up.sh             # platform + dev + prod clusters, Argo CD, root app
```

For AKS, EKS or GKE: `cp bootstrap/<cloud>/env.example bootstrap/<cloud>/env`, edit it, then run `bootstrap/<cloud>/up.sh --dry-run`. Cloud clusters cost money, so tear them down with `bootstrap/<cloud>/down.sh` when you're done. The [manual kind walkthrough](docs/local-kind-setup.md) shows every step the script automates.

## How the fleet works

```text
Git repository (your fork)
	|
	| root-app.yaml
	v
Argo CD on the hub / platform cluster
	|
	| reads applicationsets/
	v
Generated Argo CD Applications, one set per file in clusters/
	|-- dev:  namespaces, Helm add-ons, Kyverno policies, tenants, Alloy agent, examples
	|-- prod: namespaces, Helm add-ons, Kyverno policies, tenants, Alloy agent, examples
	|-- hub:  Loki and Grafana
```

Change fleet inputs in Git; Argo CD generates the per-cluster Applications. The [architecture page](docs/fleet-architecture.md) has the sync flow, and [docs/](docs/README.md) maps every folder.

## Key Files

| Area | Start here | What it teaches |
| --- | --- | --- |
| Bootstrap | [root-app.yaml](root-app.yaml) | App-of-apps entry point applied to the Argo CD cluster. |
| Fleet inventory | [clusters/dev.yaml](clusters/dev.yaml), [clusters/prod.yaml](clusters/prod.yaml) | Cluster name, API server, environment, region, upgrade wave, and Loki endpoint. |
| Application generation | [applicationsets/README.md](applicationsets/README.md) | Git, list, matrix, and selector generators. |
| Platform add-ons | [addons/README.md](addons/README.md) | Namespaces, Helm add-ons, Kyverno, and observability agents. |
| Tenant namespace requests | [requests/namespaces/product-a.yaml](requests/namespaces/product-a.yaml) | Small YAML interface for teams requesting namespaces. |
| Tenant namespace chart | [charts/tenant-namespace/README.md](charts/tenant-namespace/README.md) | How request YAML becomes a Kubernetes Namespace. |
| Policy model | [addons/kyverno-policies/README.md](addons/kyverno-policies/README.md) | How Kyverno reacts to namespace labels. |
| Workload example | [examples/guestbook-rollout/README.md](examples/guestbook-rollout/README.md) | A sample app deployed across the fleet. |

## Repository Hygiene Included

| What | Where | Why |
| --- | --- | --- |
| Manifest validation | [scripts/validate.sh](scripts/validate.sh), [.github/workflows/validate.yaml](.github/workflows/validate.yaml) | `kustomize build`, `helm template` and `kubeconform` on every PR, so Argo CD never sees broken YAML. |
| Dependency updates | [renovate.json](renovate.json) | Chart versions stay pinned and get bumped in reviewable PRs. |
| Review boundaries | [.github/CODEOWNERS](.github/CODEOWNERS), [PR template](.github/pull_request_template.md) | Platform review for inventory, policies and namespace lifecycle. |
| Workshop site | [.github/workflows/pages.yaml](.github/workflows/pages.yaml) | Publishes `site/` to GitHub Pages. |
| Moving the repo | [scripts/set-repo-url.sh](scripts/set-repo-url.sh) | Rewrites every `repoURL` in one go for a fork or a new home. |

## Safety Notes

- The sample uses automated sync and prune so the behavior is visible. Deleting a namespace request can delete the namespace and the resources inside it.
- Local kind API server IPs can change when clusters are recreated. Update [clusters/dev.yaml](clusters/dev.yaml), [clusters/prod.yaml](clusters/prod.yaml), and the Argo CD cluster registrations together.
- The observability endpoint in each cluster file is intentionally simple. Real clusters need a reachable Loki endpoint across cluster boundaries.
- Before using this pattern for real teams, add branch protection, CODEOWNERS, request schema validation, chart value review, and a reviewed namespace deletion process.

## Common Changes

| Change | File to edit | What happens |
| --- | --- | --- |
| Add a cluster | Add a file under [clusters/](clusters/) and register that cluster in Argo CD. | ApplicationSets generate the platform add-ons, policies, agents, and examples for the new cluster. |
| Add a tenant namespace | Add a request under [requests/namespaces/](requests/namespaces/). | The tenant namespace chart creates the namespace only in the requested environments. |
| Add a platform namespace | Edit [addons/namespaces/base/platform-namespaces.yaml](addons/namespaces/base/platform-namespaces.yaml). | The namespace appears on every cluster through the environment overlays. |
| Add a Helm add-on | Add an element in [applicationsets/platform-helm-addons-appset.yaml](applicationsets/platform-helm-addons-appset.yaml). | The matrix generator installs that chart once per cluster. |
| Add tenant policy | Add a Kyverno policy and include it from a Kustomize overlay under [addons/kyverno-policies/](addons/kyverno-policies/). | Kyverno matches tenant namespace labels and generates or mutates resources. |
| Add a workload example | Add manifests under [examples/](examples/) and an ApplicationSet under [applicationsets/](applicationsets/). | The workload can deploy across the same cluster inventory. |

## About

Written and maintained by [Daniel Abrahamberg](https://www.abrahamberg.com/) ([GitHub](https://github.com/abrahamberg), [LinkedIn](https://www.linkedin.com/in/abrahamberg/)). The material was first delivered as a workshop with [PlatformEngr](https://www.platformengr.com/), which helps growing teams build and run their internal platforms.

Found a mistake or have an idea? Issues and PRs are welcome.
