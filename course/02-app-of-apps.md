# 02 App of apps

**Goal:** bootstrap many Applications from a single root Application, and put a fence around them with an AppProject.
**Time:** 30 minutes

**You'll touch:** [labs/02-app-of-apps/](labs/02-app-of-apps/), [root-app.yaml](../root-app.yaml), [applicationsets/fleet-platform-project.yaml](../applicationsets/fleet-platform-project.yaml)

## Concepts

Applying every Application by hand doesn't scale and isn't GitOps. The fix: Applications are Kubernetes resources too, so let Argo CD manage them **from Git**.

```text
kubectl apply (once)
        |
        v
  +-----------+      syncs path: course/labs/02-app-of-apps/apps
  | lab-root  | -----------------------------------------------+
  +-----------+                                                |
                     +------------------+------------------+   |
                     v                  v                  v   |
              AppProject          Application         Application
              course-lab          lab-hello           lab-hello-config
                                      |                    |
                                      v                    v
                               ns lab-hello          ns lab-config
```

The root is the **only** thing you apply by hand. Adding a new app becomes "add a file, open a PR".

The repo's real [root-app.yaml](../root-app.yaml) does exactly this for the fleet: it syncs the `applicationsets/` folder, which contains ApplicationSets (module 04) rather than plain Applications.

### AppProject: the boundary

An **AppProject** limits what Applications inside it may do:

| Field | Limits |
| --- | --- |
| `sourceRepos` | which Git/Helm repos they may read |
| `destinations` | which clusters and namespaces they may deploy to |
| `clusterResourceWhitelist` | which cluster-scoped kinds (Namespace, CRD, ClusterRole...) they may create |
| `namespaceResourceWhitelist` / `...Blacklist` | which namespaced kinds |
| `roles` | project-scoped RBAC (module 09) |

The `default` project allows everything. Fine for the root app, not for things teams can change.

The lab project `course-lab` allows only this repo and only `lab-*` namespaces on the hub. The fleet's [fleet-platform-project.yaml](../applicationsets/fleet-platform-project.yaml) restricts source repos but allows any destination, because the platform team owns it. Its `sync-wave: "-10"` makes sure the project exists before anything that uses it.

## Hands-on

### 1. Clean up lab 01

The new child app manages the same namespace, so remove the old one first:

```bash
kubectl -n argocd delete application hello
kubectl delete namespace lab-hello
```

(Without the `resources-finalizer.argocd.argoproj.io` finalizer, deleting an Application leaves its resources behind. That's why we delete the namespace too.)

### 2. Point the lab at your fork

```bash
grep -rl "repoURL\|sourceRepos" course/labs/02-app-of-apps | \
  xargs sed -i "s#https://github.com/abrahamberg/fleet-gitops.git#${REPO_URL}#"
git commit -am "lab02: use my fork" && git push
```

### 3. Apply the root

```bash
kubectl apply -f course/labs/02-app-of-apps/root.yaml
kubectl -n argocd get applications -w
```

You should see `lab-root` appear, then `lab-hello` and `lab-hello-config` a few seconds later.

### 4. Add an app by Git only

Create `course/labs/02-app-of-apps/apps/hello-two.yaml` by copying `hello-config.yaml`, change `metadata.name` to `lab-hello-two` and `destination.namespace` to `lab-two`. Commit, push, refresh:

```bash
git add course/labs/02-app-of-apps/apps/hello-two.yaml
git commit -m "lab02: add hello-two" && git push
argocd app get lab-root --refresh
kubectl -n argocd get applications
```

No `kubectl apply` for the new app. That's the point.

## Check yourself

```bash
kubectl -n argocd get applications
```

```text
NAME               SYNC STATUS   HEALTH STATUS
lab-hello          Synced        Healthy
lab-hello-config   Synced        Healthy
lab-hello-two      Synced        Healthy
lab-root           Synced        Healthy
```

```bash
kubectl -n argocd get appproject course-lab -o jsonpath='{.spec.destinations[0].namespace}{"\n"}'
```

```text
lab-*
```

## Break it on purpose

**1. Cross the boundary.** Edit `hello-two.yaml` and set `destination.namespace: kube-system`. Push and refresh.

```bash
kubectl -n argocd get application lab-hello-two \
  -o jsonpath='{.status.conditions[*].message}{"\n"}'
```

You'll see a message that the destination is not permitted in project `course-lab`. Nothing reached `kube-system`. This is the guardrail working. Revert the change.

**2. Delete a child app by hand.**

```bash
kubectl -n argocd delete application lab-hello-config
kubectl -n argocd get applications -w
```

The root recreates it, because the child's manifest is still in Git. The only real way to remove an app is to remove its file.

**3. Delete its file.** `git rm course/labs/02-app-of-apps/apps/hello-two.yaml`, push, refresh. The root prunes `lab-hello-two`. Note the namespace `lab-two` survives: the child had no resources finalizer. Decide consciously which behavior you want; the fleet's tenant ApplicationSet (module 06) uses the finalizer on purpose.

## Field notes

- Keep the root app boring: `project: default`, one path, automated sync. Everything interesting goes below it, where projects and reviews apply.
- People often put the root app in the same folder it syncs. Then it manages itself, and one bad commit can delete the thing that would fix it. Keep root outside its own path, like `root-app.yaml` here.
- In the workshop, the "cross the boundary" exercise was the moment AppProjects stopped feeling like paperwork. Do it with a colleague watching.

## Quiz

1. Why is the root Application the only manifest applied by hand?
2. A child app is deleted with `kubectl` but its file is still in Git. What happens?
3. What does an AppProject `destinations` list protect against?

<details>
<summary>Answers</summary>

1. Everything else comes from Git through it, so the cluster state is reproducible from one command plus the repo.
2. The root (with automated sync + self-heal) recreates it on its next reconcile.
3. Applications in that project deploying to clusters/namespaces they shouldn't, e.g. a team app writing into `kube-system` or into prod.

</details>

**Next:** [03 Fleet inventory](03-fleet-inventory.md)
