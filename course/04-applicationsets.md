# 04 ApplicationSets

**Goal:** generate one Application per cluster (or per cluster x add-on) from templates, and read the repo's ApplicationSets fluently.
**Time:** 45 minutes

**You'll touch:** [applicationsets/guestbook-appset.yaml](../applicationsets/guestbook-appset.yaml), [applicationsets/platform-helm-addons-appset.yaml](../applicationsets/platform-helm-addons-appset.yaml), [applicationsets/wave-demo-appset.yaml](../applicationsets/wave-demo-appset.yaml), [applicationsets/README.md](../applicationsets/README.md)

## Concepts

An **ApplicationSet** = **generators** (produce a list of parameter sets) + a **template** (an Application with placeholders). The controller renders one Application per parameter set and keeps them in sync: new parameter set, new app; parameter set gone, app gone.

```text
  generator output                     template                     result
 +---------------------------+      +---------------------+      +----------------------+
 | {name: dev,  server: ..3} | ---> | name: {{name}}-gb   | ---> | dev-guestbook        |
 | {name: prod, server: ..4} | ---> | server: {{server}}  | ---> | prod-guestbook       |
 +---------------------------+      +---------------------+      +----------------------+
```

### Generators you'll use

| Generator | Parameters come from | Used here |
| --- | --- | --- |
| **list** | inline `elements` | add-on catalog in `platform-helm-addons` |
| **git files** | fields of YAML/JSON files in a repo | `clusters/*.yaml`, `requests/namespaces/*.yaml` |
| **cluster** | Argo CD cluster Secrets and their labels | (alternative to git files) |
| **matrix** | cartesian product of two generators | clusters x add-ons, clusters x namespace requests |
| **merge** | combine generators, overriding by key | per-cluster overrides (not used here) |

**Selectors** filter a generator's output: `wave-demo` keeps only parameter sets where `upgradeWave` is `"0"`.

```yaml
generators:
  - git:
      files:
        - path: clusters/*.yaml
    selector:
      matchLabels:
        upgradeWave: "0"
```

### Two template syntaxes

- **fasttemplate** (default): `'{{name}}'`. Simple string replacement. `guestbook-appset.yaml` uses it.
- **Go templates** (`goTemplate: true`): `'{{ .name }}'`, with `default`, `range`, `if`, Sprig functions. `platform-helm-addons` and `tenant-namespaces` use it.

For new ApplicationSets I'd always use Go templates, plus `goTemplateOptions: ["missingkey=error"]`, so a typo in a field fails loudly instead of rendering an empty string.

### Naming and labels

Generated names should be unique and predictable: `<cluster>-<thing>` (`prod-cert-manager`). Put the dimensions on **labels** too (`environment`, `platform-addon`, `region`). You'll use them for filtering, for RBAC and for RollingSync in module 08.

## Hands-on

### 1. Read what's already generated

```bash
kubectl --context kind-platform -n argocd get applicationsets
kubectl --context kind-platform -n argocd get applications -l environment=prod
kubectl --context kind-platform -n argocd get applications -l platform-addon=kyverno
```

### 2. Write your own: a list generator

Save as `/tmp/hello-list.yaml` (a scratch file; we apply it directly to learn, not via Git):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: hello-list
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - list:
        elements:
          - cluster: dev
            replicas: "1"
          - cluster: prod
            replicas: "2"
  template:
    metadata:
      name: '{{ .cluster }}-hello'
      labels:
        course: "04"
    spec:
      project: default
      source:
        repoURL: REPLACE_WITH_REPO_URL
        targetRevision: main
        path: course/labs/01-single-app/app
        kustomize:
          replicas:
            - name: hello
              count: '{{ .replicas }}'   # quoted: the manifest must be valid YAML before templating
      destination:
        name: '{{ .cluster }}'
        namespace: lab-hello
      syncPolicy:
        automated: {}
        syncOptions:
          - CreateNamespace=true
```

```bash
sed -i "s#REPLACE_WITH_REPO_URL#${REPO_URL}#" /tmp/hello-list.yaml
kubectl --context kind-platform apply -f /tmp/hello-list.yaml
kubectl --context kind-platform -n argocd get applications -l course=04
```

Note `destination.name`: you can target a cluster by its Secret's `name` instead of `server`.

### 3. Turn it into a git-files generator

Replace the `list` generator with the inventory, and use a field from it:

```yaml
  generators:
    - git:
        repoURL: REPLACE_WITH_REPO_URL
        revision: main
        files:
          - path: clusters/*.yaml
```

Change `count` to `'{{ if eq .environment "prod" }}2{{ else }}1{{ end }}'`, and replace every `.cluster` with `.name` (the inventory's field). Apply again. Same two apps, but now driven by the inventory.

### 4. Read the matrix

Open [platform-helm-addons-appset.yaml](../applicationsets/platform-helm-addons-appset.yaml). The matrix combines `clusters/*.yaml` (2 entries) with a list of 7 add-ons: 14 Applications.

```bash
kubectl --context kind-platform -n argocd get applications -l platform-addon --no-headers | wc -l
```

## Check yourself

```bash
kubectl --context kind-platform -n argocd get applications -l course=04
```

```text
NAME         SYNC STATUS   HEALTH STATUS
dev-hello    Synced        Healthy
prod-hello   Synced        Healthy
```

```bash
kubectl --context kind-prod -n lab-hello get deploy hello -o jsonpath='{.spec.replicas}{"\n"}'
```

```text
2
```

Clean up: `kubectl --context kind-platform -n argocd delete applicationset hello-list`.

## Break it on purpose

**1. Hand-edit a generated app.** `kubectl -n argocd edit application dev-hello` and change `targetRevision` to `HEAD`. Watch it flip back: the ApplicationSet owns its Applications and overwrites manual edits. (`spec.ignoreApplicationDifferences` exists for the rare field you want to allow.)

**2. Typos with and without `missingkey=error`.** Change `{{ .name }}` to `{{ .nmae }}` in `metadata.name`. With the option, the ApplicationSet shows an error condition and generates nothing:

```bash
kubectl -n argocd get applicationset hello-list -o jsonpath='{.status.conditions[*].message}{"\n"}'
```

Remove the option and try again: the name renders as `<no value>-hello`. That's the bug you'd ship.

**3. Delete the ApplicationSet.** Its Applications go with it (they're owned). In the real fleet that's a big blast radius. Look up `preserveResourcesOnDeletion` and `applicationsetcontroller.policy` (e.g. `create-update` to never delete) in the [docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Controlling-Resource-Modification/).

## Field notes

- In the workshop, people mixed `{{name}}` and `{{ .name }}` in the same file. They are different engines; pick one per ApplicationSet. When converting old ones to Go templates, convert every placeholder.
- Values in the inventory should be strings when used in selectors (`upgradeWave: "0"`, quoted). Label selectors compare strings.
- Recent `argocd` CLI versions can render an ApplicationSet without applying it (`argocd appset generate <file>`). If yours has it, use it in review; otherwise apply to a kind hub and look.

## Quiz

1. How many Applications does a matrix of 3 clusters x 5 add-ons produce?
2. Why prefer `goTemplate: true` with `missingkey=error`?
3. You remove `clusters/dev.yaml`. What happens to `dev-guestbook`?

<details>
<summary>Answers</summary>

1. 15.
2. Go templates give you conditionals, defaults and functions; `missingkey=error` turns a missing field into a visible error instead of an empty string in a name or path.
3. The git generator no longer emits `dev`, so the ApplicationSet deletes the `dev-guestbook` Application (and, depending on finalizers and policy, its resources).

</details>

**Next:** [05 Add-ons and sync waves](05-addons-and-sync-waves.md)
