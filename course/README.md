# Fleet GitOps: a hands-on course

Learn to run a fleet of Kubernetes clusters with GitOps, step by step: from one Argo CD Application on a laptop cluster to a near-production, multi-cluster platform on AKS, EKS or GKE.

> This course started as a hands-on workshop I ran for [PlatformEngr](https://www.platformengr.com/). Attendees kept asking for the material, so it's now public. — [Daniel Abrahamberg](https://www.abrahamberg.com/)

Everything you build lives in this repository. The course does not invent a toy world and then throw it away: from module 03 onward you work with the real fleet layout in [`applicationsets/`](../applicationsets/), [`clusters/`](../clusters/), [`addons/`](../addons/), [`charts/`](../charts/) and [`requests/`](../requests/).

## What you'll end up with

```text
                 Git (this repo, your fork)
                           |
                           v   pull + reconcile
              +---------------------------+
              |  hub / platform cluster   |
              |  Argo CD, ApplicationSets |
              |  Loki + Grafana           |
              +-------------+-------------+
                            |  declarative cluster secrets
              +-------------+-------------+
              v                           v
     +----------------+          +----------------+
     |  dev cluster   |          |  prod cluster  |
     |  add-ons,      |          |  add-ons,      |
     |  Kyverno,      |          |  Kyverno,      |
     |  tenants,      |          |  tenants,      |
     |  Alloy agent   |          |  Alloy agent   |
     +----------------+          +----------------+
```

## Outline

| Level | Module | Time | You'll be able to |
| --- | --- | --- | --- |
| 1 Foundations | [00 Welcome](00-welcome.md) | 15 min | Pick a track and get your tools ready |
| 1 Foundations | [01 GitOps in one cluster](01-gitops-in-one-cluster.md) | 45 min | Install Argo CD, deploy one Application, watch drift self-heal |
| 1 Foundations | [02 App of apps](02-app-of-apps.md) | 30 min | Bootstrap many apps from one root, fence them with an AppProject |
| 2 Fleet | [03 Fleet inventory](03-fleet-inventory.md) | 45 min | Register dev/prod spokes and describe them in `clusters/*.yaml` |
| 2 Fleet | [04 ApplicationSets](04-applicationsets.md) | 45 min | Generate apps per cluster with list, git, matrix and selectors |
| 2 Fleet | [05 Add-ons and sync waves](05-addons-and-sync-waves.md) | 45 min | Ship Helm add-ons and Kustomize overlays per environment, in order |
| 3 Platform | [06 Tenants and guardrails](06-tenants-and-guardrails.md) | 45 min | Onboard a team by PR, enforce defaults with Kyverno |
| 3 Platform | [07 Observability](07-observability.md) | 40 min | Ship logs from every spoke to Loki/Grafana on the hub |
| 3 Platform | [08 Progressive delivery](08-progressive-delivery.md) | 50 min | Roll changes dev-then-prod with waves, RollingSync and canaries |
| 4 Production | [09 Secrets and identity](09-secrets-and-identity.md) | 50 min | Pull secrets from a cloud vault with workload identity; SSO + RBAC |
| 4 Production | [10 Going to cloud](10-going-to-cloud.md) | 60-90 min | Run the fleet on AKS, EKS or GKE without long-lived tokens |
| 4 Production | [11 Production checklist](11-production-checklist.md) | 45 min | HA, pinning, CI validation, DR, upgrades, day-2 runbook |

Total: roughly one long day, or four evenings (one per level).

## Choose your track

| Track | Cost | Good for | Shortcut |
| --- | --- | --- | --- |
| **kind** (default) | free, local | learning every module, offline-ish | [`bootstrap/kind/up.sh`](../bootstrap/kind/up.sh) |
| **AKS** | cloud bill | teams on Azure | [`bootstrap/aks/up.sh`](../bootstrap/aks/up.sh) |
| **EKS** | cloud bill | teams on AWS | [`bootstrap/eks/up.sh`](../bootstrap/eks/up.sh) |
| **GKE** | cloud bill | teams on Google Cloud | [`bootstrap/gke/up.sh`](../bootstrap/gke/up.sh) |

My advice: do levels 1-3 on kind even if you will end up in a cloud. Mistakes are free there, and `kind delete cluster` is the best undo button in the industry. Switch to your cloud at module 10.

Every cloud script supports `--dry-run` (prints what it would do) and reads its settings from `bootstrap/<cloud>/env` (copy `env.example`).

## How each module is laid out

1. **Goal** and **time**
2. **You'll touch**: the repo files involved
3. **Concepts**: the minimum theory, with a diagram where it helps
4. **Hands-on**: exact commands (kind by default; cloud differences called out)
5. **Check yourself**: commands and the output you should see
6. **Break it on purpose**: a safe experiment to build intuition
7. **Field notes**: practical tips from running the workshop
8. **Quiz**: three questions, answers folded away

## Conventions

- Contexts follow kind naming: `kind-platform` (hub), `kind-dev`, `kind-prod`.
- `REPO_URL` is your fork, e.g. `export REPO_URL=https://github.com/<you>/fleet-gitops.git`. Argo CD pulls from Git, so it needs a repo **you can push to**.
- Commands run from the repository root unless stated otherwise.

---

<sub>Made by [Daniel Abrahamberg](https://www.abrahamberg.com/) · first run as a [PlatformEngr](https://www.platformengr.com/) workshop · [GitHub](https://github.com/abrahamberg) · [LinkedIn](https://www.linkedin.com/in/abrahamberg/)</sub>
