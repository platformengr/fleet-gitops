# Fleet GitOps

**A reference repository for running a fleet of Kubernetes clusters with Argo CD.** One hub cluster generates and manages the Applications for every workload cluster from a Git inventory: platform add-ons, tenant namespaces with guardrails, observability agents and sample workloads.

This repo is the hands-on half of a free course by [PlatformEngr](https://www.platformengr.com/), written by [Daniel Abrahamberg](https://www.abrahamberg.com/). It started as a workshop and is now public.

> **Learn it step by step:** the guided workshop, the Markdown course and a script generator for kind, AKS, EKS and GKE live at **https://www.platformengr.com/learn/fleet-gitops/**. This repo is what you fork, clone or recreate as you follow along.

## Use it

| Path | How |
| --- | --- |
| **Fork and explore** | Fork this repo, clone your fork, then run `scripts/set-repo-url.sh <your-fork-url>` and push. Argo CD reads from Git, so it needs a repo you can push to. |
| **Build your own** | Create an empty repo and add the files as the course introduces them. Every file you need is in this repo as the reference answer. |

Either way, the course's bootstrap scripts create the clusters and install Argo CD, and apply `root-app.yaml` from your repo.

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

Change fleet inputs in Git; Argo CD generates the per-cluster Applications. [docs/fleet-architecture.md](docs/fleet-architecture.md) has the sync flow, and [docs/](docs/README.md) maps every folder.

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

## Included Repository Hygiene

| What | Where | Why |
| --- | --- | --- |
| Manifest validation | [scripts/validate.sh](scripts/validate.sh), [.github/workflows/validate.yaml](.github/workflows/validate.yaml) | `kustomize build`, `helm template` and `kubeconform` on every PR, so Argo CD never sees broken YAML. |
| Dependency updates | [renovate.json](renovate.json) | Chart versions stay pinned and get bumped in reviewable PRs. |
| Review boundaries | [.github/CODEOWNERS](.github/CODEOWNERS), [PR template](.github/pull_request_template.md) | Platform review for inventory, policies and namespace lifecycle. |
| Pointing at your repo | [scripts/set-repo-url.sh](scripts/set-repo-url.sh) | Rewrites every `repoURL` in one go for a fork or a new home. |

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

Maintained by [PlatformEngr](https://www.platformengr.com/), which helps growing teams build and run their internal platforms, with [Daniel Abrahamberg](https://www.abrahamberg.com/) ([LinkedIn](https://www.linkedin.com/in/abrahamberg/)). Issues and PRs are welcome.
