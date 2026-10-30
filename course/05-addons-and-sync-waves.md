# 05 Add-ons and sync waves

**Goal:** ship the same platform add-ons to every cluster with environment-specific settings, and understand what does (and doesn't) control their order.
**Time:** 45 minutes

**You'll touch:** [applicationsets/platform-helm-addons-appset.yaml](../applicationsets/platform-helm-addons-appset.yaml), [applicationsets/platform-addons-appset.yaml](../applicationsets/platform-addons-appset.yaml), [applicationsets/kyverno-policies-appset.yaml](../applicationsets/kyverno-policies-appset.yaml), [addons/](../addons/), [docs/kustomize-overlays.md](../docs/kustomize-overlays.md)

## Concepts

### Two ways to package an add-on

| | Helm via matrix | Kustomize base/overlays |
| --- | --- | --- |
| Used for | third-party software (cert-manager, ingress-nginx, Kyverno...) | your own manifests (namespaces, Kyverno policies) |
| Lives in | upstream chart repo; version pinned in the ApplicationSet list | `addons/<name>/base` + `overlays/{dev,prod}` |
| Per-env differences | Go template conditions on `.environment`, or a values file per env | an overlay per env, picked by `path: addons/<name>/overlays/{{environment}}` |

```text
addons/kyverno-policies/
  base/                       shared: default-deny netpol, PSA labels
  overlays/dev/   -> base + LimitRange
  overlays/prod/  -> base + LimitRange + ResourceQuota
        ^
        | path: addons/kyverno-policies/overlays/{{environment}}
        |
  clusters/prod.yaml: environment: prod
```

### Sync waves: what they really order

`argocd.argoproj.io/sync-wave: "N"` orders **resources inside one Application's sync**: lower waves are applied and must be healthy before the next wave starts. Typical uses: Namespace and CRDs in wave `-1`, workloads in `0`, a smoke-test Job hook in `1`.

Across Applications it's subtler:

- **App of apps**: the parent syncs child `Application` resources in wave order. For the parent to *wait* for a child to be healthy, Argo CD needs a health check for `argoproj.io/Application`, which is not enabled by default since v1.8. See [the docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/health/#argocd-app).
- **ApplicationSet-generated Applications**: these are created by the ApplicationSet controller, not by a parent sync. A `sync-wave` annotation on them **does not** order them against each other.

So in this repo, the waves on generated apps (`cert-manager` 1, `ingress-nginx` 2, ..., `kyverno` 6, `kyverno-policies` 7, tenants 8, agents 9) document the intended dependency order. What makes the fleet converge in practice is:

1. Each add-on owns its CRDs (`installCRDs: true`) inside its own Application, ordered by Helm and Argo CD within that app.
2. Apps that depend on another app's CRDs fail fast and succeed on a later attempt. Adding `syncPolicy.retry` with backoff makes that automatic instead of "wait for the next commit".
3. For real ordering across apps per cluster, use RollingSync (module 08) or put tightly coupled pieces in one Application.

I'd rather you learn this here than at 11pm during an upgrade.

### ServerSideApply

`ServerSideApply=true` makes Argo CD use Kubernetes server-side apply. You want it for large CRDs (kube-prometheus-stack, Kyverno), which exceed the client-side `last-applied-configuration` annotation limit, and for shared ownership of fields with other controllers.

## Hands-on

### 1. Render what Argo CD will render

```bash
kubectl kustomize addons/kyverno-policies/overlays/dev  | grep -E '^kind:|^  name:'
kubectl kustomize addons/kyverno-policies/overlays/prod | grep -E '^kind:|^  name:'
diff <(kubectl kustomize addons/kyverno-policies/overlays/dev) \
     <(kubectl kustomize addons/kyverno-policies/overlays/prod)
```

Prod has one more policy: `tenant-prod-resource-quota`.

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm template cert-manager jetstack/cert-manager --version v1.15.3 \
  --set installCRDs=true | grep -c '^kind: CustomResourceDefinition'
```

### 2. See the add-ons per cluster

```bash
kubectl --context kind-platform -n argocd get applications -l environment=dev \
  -o custom-columns=NAME:.metadata.name,WAVE:.metadata.annotations.argocd\\.argoproj\\.io/sync-wave,SYNC:.status.sync.status,HEALTH:.status.health.status
```

### 3. Add a platform namespace to dev only

```bash
git switch -c dev-sandbox-ns
cat > addons/namespaces/overlays/dev/sandbox.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: platform-sandbox
EOF
yq -i '.resources += ["sandbox.yaml"]' addons/namespaces/overlays/dev/kustomization.yaml
kubectl kustomize addons/namespaces/overlays/dev | grep platform-sandbox
git add -A && git commit -m "dev: platform-sandbox namespace"
```

Merge it into `main` of your fork (PR or `git switch main && git merge dev-sandbox-ns && git push`), then refresh `dev-platform-namespaces`.

### 4. Per-environment Helm values (read, don't commit)

In `platform-helm-addons-appset.yaml` each add-on's `values` is one string shared by all clusters. With Go templates you can branch on the cluster's environment inside the template, for example:

```yaml
        helm:
          releaseName: '{{ .addon }}'
          values: |-
            {{ .values | nindent 12 }}
            {{- if eq .environment "prod" }}
            # prod-only overrides here
            {{- end }}
```

It works, but it becomes unreadable after two or three differences. Past that, I'd keep a values file per environment in Git (`addons/<name>/values-<env>.yaml`) and use a [multi-source Application](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/): chart from the Helm repo, values from this repo via `$values/addons/{{ .addon }}/values-{{ .environment }}.yaml`.

## Check yourself

```bash
kubectl --context kind-dev  get ns platform-sandbox
kubectl --context kind-prod get ns platform-sandbox
```

```text
NAME               STATUS   AGE
platform-sandbox   Active   1m
Error from server (NotFound): namespaces "platform-sandbox" not found
```

```bash
kubectl --context kind-platform -n argocd get applications -l platform-addon --no-headers | awk '{print $2, $3}' | sort | uniq -c
```

Mostly `Synced Healthy`. Anything else, open it with `argocd app get <name>`.

## Break it on purpose

**1. Pull a CRD out from under its dependents.** Delete Kyverno's ClusterPolicy CRD on dev (this also deletes every ClusterPolicy on dev):

```bash
kubectl --context kind-dev delete crd clusterpolicies.kyverno.io
kubectl --context kind-platform -n argocd get applications dev-kyverno dev-kyverno-policies -w
```

`dev-kyverno` goes OutOfSync and self-heals by re-creating the CRD. `dev-kyverno-policies` goes OutOfSync (its policies vanished) and recovers only once the CRD is back; if it tried in between, its sync failed because the kind didn't exist. That's a cross-app dependency, resolved by self-heal and retries rather than by waves.

**2. Turn off ServerSideApply for kube-prometheus-stack** in a scratch copy of the ApplicationSet applied to your kind hub only. The sync fails with an error about annotations being too long. Put it back.

## Field notes

- In the workshop, the most common surprise in this module was the "waves on generated apps don't order them" point. People had relied on it without noticing, because retries hid the problem.
- Pin every chart version (this repo does). `targetRevision: "*"` turns every upstream release into an unreviewed production change.
- When an add-on fails on first sync because a CRD isn't there yet, `SkipDryRunOnMissingResource=true` (sync option) is often the right fix for that one app; don't sprinkle it everywhere.

## Quiz

1. Which mechanism picks `overlays/prod` for the prod cluster?
2. Does a `sync-wave` annotation on ApplicationSet-generated Applications order them against each other?
3. Why does kube-prometheus-stack need `ServerSideApply=true`?

<details>
<summary>Answers</summary>

1. The ApplicationSet template's path `addons/<name>/overlays/{{environment}}`, with `environment` coming from `clusters/prod.yaml` through the Git files generator.
2. No. Waves order resources within one sync (and child Applications within an app-of-apps sync). Generated apps are created by the ApplicationSet controller; use retries, RollingSync or bundling for ordering.
3. Its CRDs are too large for the client-side apply annotation; server-side apply doesn't store that annotation.

</details>

**Next:** [06 Tenants and guardrails](06-tenants-and-guardrails.md)
