# 01 GitOps in one cluster

**Goal:** install Argo CD on one kind cluster, deploy one Application from Git, and watch it undo a manual change.
**Time:** 45 minutes

**You'll touch:** [labs/01-single-app/application.yaml](labs/01-single-app/application.yaml), [labs/01-single-app/app/](labs/01-single-app/app/)

## Concepts

GitOps is four principles ([OpenGitOps](https://opengitops.dev/)):

1. **Declarative**: you describe the desired state (YAML), not the steps.
2. **Versioned and immutable**: that description lives in Git; history is your audit log and your undo.
3. **Pulled automatically**: an agent in the cluster fetches it. CI never needs cluster credentials.
4. **Continuously reconciled**: the agent keeps comparing live state to Git and fixes drift.

```text
   git push                     every ~3 min (or webhook)
 you -------> Git repo <-----------------------------+
                                                     |
                                    +----------------+---------------+
                                    |  Argo CD                       |
                                    |  repo-server: render manifests |
                                    |  app-controller: diff + apply  |
                                    +----------------+---------------+
                                                     | apply
                                                     v
                                               Kubernetes API
```

An Argo CD **Application** is one pairing of *source* (repo, revision, path) and *destination* (cluster, namespace). Two statuses matter:

- **Sync status**: does live state match Git? (`Synced` / `OutOfSync`)
- **Health status**: is it actually working? (`Healthy` / `Progressing` / `Degraded` ...)

`syncPolicy.automated` makes Argo CD apply changes by itself; `selfHeal: true` makes it revert manual edits; `prune: true` lets it delete things you removed from Git.

## Hands-on

### 1. Create the cluster

We call it `platform` because it becomes the hub in module 03.

```bash
kind create cluster --name platform
kubectl config use-context kind-platform
```

### 2. Install Argo CD (manual way)

```bash
# Pin a release tag from https://github.com/argoproj/argo-cd/releases in real use.
export ARGOCD_VERSION=stable
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

kubectl -n argocd rollout status deploy/argocd-server
kubectl -n argocd rollout status deploy/argocd-repo-server
kubectl -n argocd rollout status statefulset/argocd-application-controller
```

`--server-side` avoids the "annotation too long" error some Argo CD CRDs hit with client-side apply.

> **Shortcut:** `bootstrap/kind/up.sh` creates all three clusters and installs Argo CD on the hub with Helm (values in `bootstrap/argocd/values-local.yaml`). Use the manual way here once; it's worth seeing the moving parts.

### 3. Open the UI

```bash
# terminal 1
kubectl -n argocd port-forward svc/argocd-server 8080:443

# terminal 2
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Browse to https://localhost:8080, user `admin`. (Module 09 replaces this admin password with SSO.)

Optional CLI login:

```bash
argocd login localhost:8080 --username admin --insecure \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
```

### 4. Point the lab at your fork

```bash
sed -i "s#repoURL: .*#repoURL: ${REPO_URL}#" course/labs/01-single-app/application.yaml
git commit -am "lab01: use my fork" && git push
```

(macOS: `sed -i ''`.)

### 5. Deploy one Application

Look at what you're about to apply. It's 20 lines: source, destination, sync policy.

```bash
cat course/labs/01-single-app/application.yaml
kubectl apply -f course/labs/01-single-app/application.yaml
kubectl -n argocd get application hello -w
```

### 6. Make a change the GitOps way

Edit `course/labs/01-single-app/app/deployment.yaml`, set `replicas: 3`, then:

```bash
git commit -am "lab01: scale hello to 3" && git push
argocd app get hello --refresh   # or click "Refresh" in the UI; otherwise wait up to ~3 min
kubectl -n lab-hello get deploy hello
```

## Check yourself

```bash
kubectl -n argocd get application hello
```

```text
NAME    SYNC STATUS   HEALTH STATUS
hello   Synced        Healthy
```

```bash
kubectl -n lab-hello get deploy hello -o jsonpath='{.spec.replicas}{"\n"}'
```

```text
3
```

## Break it on purpose

**1. Drift and self-heal.** Scale by hand and watch Argo CD put it back:

```bash
kubectl -n lab-hello scale deploy hello --replicas=10
kubectl -n lab-hello get deploy hello -w
```

Within seconds it returns to 3. Look at the app's history in the UI: the self-heal shows up as a sync.

**2. Delete a managed resource.**

```bash
kubectl -n lab-hello delete svc hello
kubectl -n lab-hello get svc -w
```

It comes back. Now imagine that was someone "cleaning up" prod at 2am.

**3. Turn self-heal off.** Remove `selfHeal: true` from `application.yaml`, `kubectl apply` it, scale by hand again. The app goes `OutOfSync` and stays that way. Run `argocd app diff hello` to see exactly what drifted. Put `selfHeal` back when you're done.

## Field notes

- In the workshop, almost everyone waited for a sync that was already done: the default poll interval is about three minutes. Use **Refresh** (or a Git webhook in real setups) instead of staring at the screen.
- `selfHeal` is great for platform components and arguable for apps under active debugging. I keep it on everywhere and teach people to debug with `argocd app diff` rather than `kubectl edit`.
- Read the **diff** before you read the logs. Nine out of ten "Argo is broken" moments are a field someone set by hand, or a default the API server adds.

## Quiz

1. What's the difference between sync status and health status?
2. What does `prune: true` do, and why is it a deliberate choice?
3. Why does pull-based delivery improve security compared to `kubectl apply` from CI?

<details>
<summary>Answers</summary>

1. Sync compares live state to Git (`Synced`/`OutOfSync`). Health says whether the resources work (`Healthy`, `Progressing`, `Degraded`). An app can be Synced but Degraded (e.g. a bad image tag committed to Git).
2. It deletes resources that exist in the cluster but were removed from Git. Without it, deleted manifests leave orphans behind; with it, deleting a file deletes real things, so reviews matter.
3. The cluster pulls; CI never holds cluster-admin credentials. The only write path is Git, which is reviewed and audited.

</details>

**Next:** [02 App of apps](02-app-of-apps.md)
