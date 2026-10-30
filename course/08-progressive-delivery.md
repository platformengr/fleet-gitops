# 08 Progressive delivery

**Goal:** make changes reach `dev` before `prod`, at fleet level (waves, RollingSync) and inside a cluster (Argo Rollouts canary), with Git as the promotion mechanism.
**Time:** 50 minutes

**You'll touch:** [applicationsets/wave-demo-appset.yaml](../applicationsets/wave-demo-appset.yaml), [applicationsets/guestbook-appset.yaml](../applicationsets/guestbook-appset.yaml), [examples/guestbook-rollout/rollout.yaml](../examples/guestbook-rollout/rollout.yaml), [clusters/*.yaml](../clusters/) (`upgradeWave`)

## Concepts

Look at [guestbook-appset.yaml](../applicationsets/guestbook-appset.yaml): every cluster points at the same path on `main`. Change the image and dev and prod both get it within minutes. That's fine for a demo and bad for production. Three layers fix it:

```text
 Layer            Controls                          Tool in this repo
 ---------------  --------------------------------  -------------------------------
 1 which clusters  dev first, then prod              upgradeWave + generator selector
 2 when, in order  sync step N only after N-1 healthy ApplicationSet RollingSync
 3 inside cluster  % of pods on the new version      Argo Rollouts canary
```

### 1. Upgrade waves via selectors

Each inventory file has `upgradeWave` (`dev` = `"0"`, `prod` = `"1"`). [wave-demo-appset.yaml](../applicationsets/wave-demo-appset.yaml) only targets wave 0:

```yaml
selector:
  matchLabels:
    upgradeWave: "0"
```

Promotion = a PR that widens the selector (or a PR that moves a cluster to an earlier wave). It's explicit, reviewable and trivially revertible. The cost: it's a manual step per wave, and "dev is healthy" is a human judgment.

A common extension: give each wave its own `targetRevision` (a tag or branch per wave) so prod stays on the last promoted commit while dev follows `main`.

### 2. ApplicationSet progressive sync (RollingSync)

RollingSync lets one ApplicationSet roll out in **steps** selected by Application labels. Step 2 starts only when step 1's apps are synced and healthy.

```yaml
spec:
  strategy:
    type: RollingSync
    rollingSync:
      steps:
        - matchExpressions:
            - key: environment
              operator: In
              values: [dev]
        - matchExpressions:
            - key: environment
              operator: In
              values: [prod]
          maxUpdate: 1        # at most one prod app syncing at a time (int or %)
```

Things to know before you rely on it:

- It is **off by default**. Enable it in the ApplicationSet controller: `applicationsetcontroller.enable.progressive.syncs: "true"` in `argocd-cmd-params-cm` (or the `--enable-progressive-syncs` flag), then restart the controller. With the Helm chart, set it under `configs.params`.
- It works on **labels of generated Applications**, so your template must set them (this repo's templates already set `environment`).
- The controller drives syncs itself. In the versions I've used, it disables automated sync on the generated apps and logs a warning if the template asks for it. Check the [Progressive Syncs docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Progressive-Syncs/) for your version; the feature has been evolving.
- Progress is in `status.applicationStatus` on the ApplicationSet.

### 3. Argo Rollouts canary

A `Rollout` replaces a `Deployment` and adds steps:

```yaml
strategy:
  canary:
    steps:
      - setWeight: 20
      - pause: {duration: 30s}
      - setWeight: 50
      - pause: {duration: 1m}
```

Without a traffic router (ingress/mesh), weight is approximated by pod count: with 3 replicas, "20%" means 1 new pod. Add an `AnalysisTemplate` (e.g. a Prometheus query) to make promotion automatic and abort on bad metrics.

## Hands-on

### 1. Waves: promote wave-demo from dev to prod

```bash
kubectl --context kind-platform -n argocd get applications | grep wave-demo
```

Only `dev-wave-demo`. Now promote by PR:

```bash
git switch -c promote-wave-demo
yq -i 'del(.spec.generators[0].selector.matchLabels) |
       .spec.generators[0].selector.matchExpressions = [{"key":"upgradeWave","operator":"In","values":["0","1"]}]' \
  applicationsets/wave-demo-appset.yaml
git diff
git commit -am "wave-demo: promote to wave 1" && git switch main && git merge promote-wave-demo && git push
```

Refresh `fleet-platform-config`; `prod-wave-demo` appears.

### 2. Canary: change the image in Git

Install the kubectl plugin from the [Argo Rollouts releases](https://github.com/argoproj/argo-rollouts/releases) (`kubectl-argo-rollouts`), then:

```bash
sed -i 's#argoproj/rollouts-demo:blue#argoproj/rollouts-demo:yellow#' examples/guestbook-rollout/rollout.yaml
git commit -am "guestbook: yellow" && git push
kubectl --context kind-dev -n guestbook argo rollouts get rollout guestbook --watch
```

You'll see the canary step through 20% and 50% with pauses. Notice prod is doing the same thing at the same time: that's the problem RollingSync solves next.

### 3. RollingSync: dev, then prod, automatically

Enable the feature on the hub:

```bash
kubectl --context kind-platform -n argocd patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"applicationsetcontroller.enable.progressive.syncs":"true"}}'
kubectl --context kind-platform -n argocd rollout restart deploy/argocd-applicationset-controller
```

(If you installed with `bootstrap/kind/up.sh`, this is already on: see `configs.params` in [bootstrap/argocd/values-local.yaml](../bootstrap/argocd/values-local.yaml). Skip the patch; with Helm installs, change the values file, not the ConfigMap, or Helm undoes it on the next upgrade.)

Save as `/tmp/guestbook-rolling.yaml`, replacing `REPO_URL`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: guestbook-rolling
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: REPO_URL
        revision: main
        files:
          - path: clusters/*.yaml
  strategy:
    type: RollingSync
    rollingSync:
      steps:
        - matchExpressions:
            - {key: environment, operator: In, values: [dev]}
        - matchExpressions:
            - {key: environment, operator: In, values: [prod]}
  template:
    metadata:
      name: '{{ .name }}-guestbook-rolling'
      labels:
        environment: '{{ .environment }}'
    spec:
      project: fleet-platform
      source:
        repoURL: REPO_URL
        targetRevision: main
        path: examples/guestbook-rollout
      destination:
        server: '{{ .server }}'
        namespace: guestbook-rolling
      syncPolicy:
        syncOptions:
          - CreateNamespace=true
```

```bash
sed -i "s#REPO_URL#${REPO_URL}#g" /tmp/guestbook-rolling.yaml
kubectl --context kind-platform apply -f /tmp/guestbook-rolling.yaml
kubectl --context kind-platform -n argocd get applicationset guestbook-rolling \
  -o jsonpath='{range .status.applicationStatus[*]}{.application}{"\t"}{.status}{"\t"}{.step}{"\n"}{end}'
```

Then flip the image back to `blue` in Git, push, and run the last command a few times. Dev moves first; prod waits until dev is healthy.

## Check yourself

```bash
kubectl --context kind-platform -n argocd get applications | grep -E 'wave-demo|guestbook-rolling'
```

```text
dev-guestbook-rolling    Synced   Healthy
dev-wave-demo            Synced   Healthy
prod-guestbook-rolling   Synced   Healthy
prod-wave-demo           Synced   Healthy
```

```bash
kubectl --context kind-prod -n guestbook-rolling get rollout guestbook -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

```text
argoproj/rollouts-demo:blue
```

## Break it on purpose

**1. Ship a bad image.** Set the image to `argoproj/rollouts-demo:does-not-exist`, push. Watch `guestbook-rolling`: dev goes Progressing/Degraded and **prod never starts**. That's the whole point. Revert in Git (that's your rollback) and watch dev recover.

**2. Abort a canary.** During a canary on dev: `kubectl --context kind-dev -n guestbook argo rollouts abort guestbook`. The Rollout scales the canary down and goes Degraded; Argo CD shows the app Degraded while Git still says "yellow". Decide: fix forward or revert in Git. Git must end up matching what you want, or self-heal and the Rollout will keep disagreeing.

## Field notes

- In the workshop, people expected RollingSync to also give them a pause "until someone approves". It doesn't; it gates on health. For a human gate, keep the wave selector PR (or a per-wave `targetRevision`) for prod.
- Promotion via Git beats promotion via buttons: the PR is the change record, and `git revert` is the rollback.
- Health checks are your safety net at every layer. A Rollout with no readiness probe and no analysis "succeeds" with a broken app. The guestbook has probes for a reason.

## Quiz

1. What does RollingSync need that the default ApplicationSet controller doesn't have on?
2. A bad commit hits dev and dev goes Degraded. With RollingSync, what happens to prod?
3. Without a traffic router, how does Argo Rollouts implement `setWeight: 20` with 3 replicas?

<details>
<summary>Answers</summary>

1. The progressive syncs feature: `applicationsetcontroller.enable.progressive.syncs: "true"` (or `--enable-progressive-syncs`), plus labels on the generated Applications for the steps to match.
2. Prod's step doesn't start, because the previous step isn't healthy.
3. By replica count: it scales the canary ReplicaSet to roughly 20% of pods (1 of 3) alongside the stable ones.

</details>

**Next:** [09 Secrets and identity](09-secrets-and-identity.md)
