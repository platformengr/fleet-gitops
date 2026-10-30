# 11 Production checklist

**Goal:** close the gap between "it works" and "I'd put my name on it": HA, pinned versions, CI validation, disaster recovery, upgrades and a day-2 runbook.
**Time:** 45 minutes

**You'll touch:** [bootstrap/argocd/](../bootstrap/argocd/) (`values-prod.yaml`), [applicationsets/](../applicationsets/), [requests/namespaces/schema.json](../requests/namespaces/schema.json), [.github/](../.github/)

## Concepts

```text
 reliability   HA Argo CD, sharding, health checks, retries
 change        pinned versions, Renovate PRs, CI validation, CODEOWNERS
 recovery      Git is the backup, Velero for volumes, rebuild drills
 operations    upgrades, cost, alerts, runbook
```

## 1. HA Argo CD

Use the official Helm chart with the `prod` profile (`bootstrap/argocd/values-prod.yaml`). The pieces that matter:

| Component | HA setting (Argo CD Helm chart) | Why |
| --- | --- | --- |
| Redis | `redis-ha.enabled: true` | cache survives a node loss |
| API server | `server.replicas: 2+` (or autoscaling) | UI/CLI/webhooks stay up |
| Repo server | `repoServer.replicas: 2+` | rendering is the usual CPU hotspot |
| ApplicationSet controller | `applicationSet.replicas: 2` | leader election |
| Application controller | `controller.replicas: N` | **sharding**: clusters are split across replicas |

Controller sharding assigns each cluster to one controller replica. The algorithm is set with `controller.sharding.algorithm` in `argocd-cmd-params-cm` (`legacy`, `round-robin`, and newer options in recent versions). With two spokes you don't need it; with twenty you will. See [High Availability](https://argo-cd.readthedocs.io/en/stable/operator-manual/high_availability/).

Also: PodDisruptionBudgets, spread across zones, resource requests sized from real usage, and `syncPolicy.retry` with backoff on Applications so transient failures don't need a new commit.

## 2. Version pinning and Renovate

Everything is pinned in this repo: chart `targetRevision`s, image tags, Argo CD itself. Pinning without an update process just means slowly going stale, so let a bot open PRs. A minimal `renovate.json` idea:

```json
{
  "extends": ["config:recommended"],
  "argocd": { "fileMatch": ["^applicationsets/.+\\.yaml$"] },
  "kubernetes": { "fileMatch": ["^(addons|examples)/.+\\.yaml$"] },
  "packageRules": [
    { "matchUpdateTypes": ["major"], "dependencyDashboardApproval": true }
  ]
}
```

Renovate's `argocd` manager understands `repoURL`/`chart`/`targetRevision` in Application specs. Charts listed inside an ApplicationSet **list generator** (like `platform-helm-addons`) are not standard fields, so you may need a `customManagers` regex entry for them. Check the [Renovate Argo CD docs](https://docs.renovatebot.com/modules/manager/argocd/).

## 3. CI validation

Argo CD will tell you a manifest is broken, after merge. CI should tell you before.

```yaml
# .github/workflows/validate.yaml (sketch)
name: validate
on: [pull_request]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Kustomize overlays render
        run: |
          for d in addons/*/overlays/*/; do
            echo "== $d"; kubectl kustomize "$d" > /dev/null
          done
      - name: Helm chart lints
        run: helm lint charts/tenant-namespace
      - name: Schemas
        run: |
          pip install check-jsonschema
          check-jsonschema --schemafile requests/namespaces/schema.json requests/namespaces/*.yaml
      - name: kubeconform
        run: |
          for d in addons/*/overlays/*/; do
            kubectl kustomize "$d" | kubeconform -strict -summary -ignore-missing-schemas \
              -schema-location default \
              -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
          done
```

(Install `kubeconform` and `kubectl` in the job, or use a container image that has them.) Add a check that every `clusters/*.yaml` has the required fields, and a diff preview: render ApplicationSets on a kind hub in CI, or use a tool that comments the rendered diff on the PR.

## 4. Backup and DR

- **Argo CD is (almost) stateless.** Its desired state is Git. Rebuild = install Argo CD, recreate cluster Secrets and repo credentials, apply `root-app.yaml`. Keep those three steps scripted (`bootstrap/<cloud>/up.sh` is most of it).
- **Git is the backup** for config. Protect `main`, require reviews, and have a mirror.
- **Persistent volumes are not in Git.** Use [Velero](https://velero.io/) (or your cloud's backup service) for PV data: Loki on the hub, team databases on spokes.
- **Drill it.** Delete the kind hub and rebuild it from Git. Time it. The number is your hub RTO.

## 5. Cost

Autoscaling node pools with sensible min/max (the bootstrap env files), a small system pool, requests on every workload (your LimitRanges enforce defaults), quotas per tenant, and log retention in Loki that matches what you actually query. Turn off non-prod at night if your teams can live with it.

## 6. Upgrades

Order I'd use: Argo CD (hub) one minor at a time, reading the upgrade notes; then add-ons via Renovate PRs, dev wave first (module 08); then Kubernetes, dev cluster first, after checking deprecated APIs (`kubent` or `pluto`).

## 7. Day-2 runbook (starter)

| Symptom | First command | Usual cause |
| --- | --- | --- |
| App `OutOfSync`, won't sync | `argocd app diff <app>` | a field mutated by a controller; consider `ignoreDifferences` |
| App `Degraded` | `argocd app get <app>` then `kubectl describe` the unhealthy resource | bad image, failing probe, missing Secret |
| Many apps `Unknown` on one cluster | `argocd cluster list` | spoke unreachable or identity revoked (module 10) |
| ApplicationSet generates nothing | `kubectl -n argocd get appset <name> -o yaml` (conditions) | template error, wrong `repoURL`, generator path |
| Git change not picked up | `argocd app get <app> --hard-refresh` | polling interval, webhook missing, wrong branch/fork |
| Repo server slow/OOM | `kubectl -n argocd top pods` | big Helm charts, too few repo-server replicas |

## Hands-on

```bash
# 1. Render everything CI would render
for d in addons/*/overlays/*/; do kubectl kustomize "$d" >/dev/null && echo "ok $d"; done
helm lint charts/tenant-namespace
check-jsonschema --schemafile requests/namespaces/schema.json requests/namespaces/*.yaml

# 2. Look at the HA profile you'd run in prod
diff bootstrap/argocd/values-local.yaml bootstrap/argocd/values-prod.yaml

# 3. DR drill on kind: destroy and rebuild the hub only
kind delete cluster --name platform
time ./bootstrap/kind/up.sh
```

## Check yourself

```bash
kubectl --context kind-platform -n argocd get applications --no-headers | awk '{print $2,$3}' | sort | uniq -c
```

After the rebuild, all apps return to `Synced Healthy`, and the spokes' workloads were never touched (spokes keep running while the hub is gone; they just stop being reconciled).

```bash
kubectl --context kind-prod -n product-a get pods,networkpolicy
```

Still there.

## Break it on purpose

**1. Commit a broken overlay in a branch** (e.g. a typo in a `resources:` entry) and run the CI loop locally. It fails before Argo CD ever sees it. That's the whole value of CI here.

**2. Kill a controller replica** on an HA install: `kubectl -n argocd delete pod argocd-application-controller-0`. With sharding, that replica's clusters pause reconciliation until it's back; the others don't notice. Know which clusters live on which shard.

## Field notes

- In the workshop, the DR drill was the exercise people most often took back to their own teams. Rebuilding the hub from Git in minutes is the best argument for GitOps you can show a manager.
- Don't skip Argo CD minor versions in prod. The upgrade notes are short; read them every time.
- Write the runbook while things are calm. Add one row every time something surprises you.

## Quiz

1. What do you need besides Git to rebuild the hub?
2. Why isn't pinning enough on its own?
3. What does controller sharding split?

<details>
<summary>Answers</summary>

1. Argo CD installed (Helm + values), cluster Secrets and repository credentials (ideally from a secret store), and `root-app.yaml` applied. PV data needs a separate backup (Velero or the cloud's).
2. Pinned versions drift out of date and accumulate security fixes you don't have. You need an update flow (Renovate PRs, CI, wave-based rollout).
3. Clusters: each managed cluster is assigned to one application-controller replica.

</details>

## Graduation

You now have a **near-production fleet**:

- one hub managing dev and prod spokes from Git, with an inventory that drives everything;
- platform add-ons per environment, tenants onboarded by reviewed PR, guardrails enforced by policy;
- central logs, per-cluster metrics, progressive rollout from dev to prod;
- secrets from a cloud vault and spoke access through workload identity, no long-lived tokens;
- a plan for HA, updates, CI, DR and day-2 operations.

What's still between you and production, honestly:

- **Your organization's specifics**: IdP groups, network topology, compliance requirements, cost ownership.
- **Real CI**: the validation sketch above as a required check, plus rendered diffs on PRs.
- **Alerting and SLOs** on the platform itself (Argo CD sync failures, ESO errors, Kyverno policy reports, node pressure).
- **Hardening**: narrower AppProjects per team instead of one wide `fleet-platform`, least-privilege spoke RBAC instead of cluster-admin, image policy.
- **Practice**: a few upgrades and one real incident handled with the runbook.

Thanks for working through it. If you build on this, I'd love to hear what you changed and why: open an issue or find me via [my blog](https://www.abrahamberg.com/).

If you want help taking this to production for your team, that's the work [PlatformEngr](https://www.platformengr.com/contact/) does.

**Back to:** [Course overview](README.md)

---

<sub>Made by [Daniel Abrahamberg](https://www.abrahamberg.com/) · first run as a [PlatformEngr](https://www.platformengr.com/) workshop</sub>
