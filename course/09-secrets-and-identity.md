# 09 Secrets and identity

**Goal:** keep secrets out of Git by pulling them from a cloud secret store with workload identity, and replace Argo CD's admin password with SSO and RBAC.
**Time:** 50 minutes

**You'll touch:** [applicationsets/platform-helm-addons-appset.yaml](../applicationsets/platform-helm-addons-appset.yaml) (the `external-secrets` entry), [addons/](../addons/), Argo CD's `argocd-cm` / `argocd-rbac-cm` (via `bootstrap/argocd/values-*.yaml`)

## Concepts

### Secrets: references in Git, values in a vault

```text
  Git: ExternalSecret "db"  ---------------------+
       (key: product-a/db-password)              |
                                                 v
  spoke: External Secrets Operator ---- ClusterSecretStore ---- workload identity ----> cloud vault
                                                 |                (no static keys)      (Key Vault /
                                                 v                                       Secrets Manager /
                                      Kubernetes Secret "db-credentials"                 Secret Manager)
```

- **External Secrets Operator (ESO)** is already in the fleet (`external-secrets` add-on).
- A **ClusterSecretStore** says *how* to reach a store. One per cluster, platform-owned.
- An **ExternalSecret** says *which* keys to fetch into which Kubernetes Secret. Lives with the app, safe to commit.
- **Workload identity** lets ESO's ServiceAccount exchange its Kubernetes token for a short-lived cloud token. No access keys in Secrets, nothing to rotate by hand.

The API group version depends on your ESO version: this repo pins chart `0.10.4`, which serves `external-secrets.io/v1beta1`. Newer releases (0.17+) serve `external-secrets.io/v1`. Use what your installed CRDs serve (`kubectl api-resources | grep external-secrets`).

### Per-cloud ClusterSecretStore

The cloud side (identity, federation/trust, vault permissions) is created outside Argo CD, by `bootstrap/<cloud>/up.sh` or your IaC. Argo CD then only ships the store. The shapes below follow the [ESO provider docs](https://external-secrets.io/latest/provider/azure-key-vault/); verify field names against your version.

**AKS + Azure Key Vault** (Azure Workload Identity; ESO's ServiceAccount annotated with `azure.workload.identity/client-id`):

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: cloud-secrets
spec:
  provider:
    azurekv:
      authType: WorkloadIdentity
      vaultUrl: https://<vault-name>.vault.azure.net
      serviceAccountRef:
        name: external-secrets
        namespace: external-secrets
```

**EKS + AWS Secrets Manager** (IRSA; ServiceAccount annotated with `eks.amazonaws.com/role-arn`. With EKS Pod Identity, drop `auth` and ESO uses the controller's own credentials):

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: cloud-secrets
spec:
  provider:
    aws:
      service: SecretsManager
      region: eu-west-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

**GKE + Google Secret Manager** (GKE Workload Identity; ServiceAccount annotated with `iam.gke.io/gcp-service-account`, or Workload Identity Federation with a direct principal binding):

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: cloud-secrets
spec:
  provider:
    gcpsm:
      projectID: <project-id>
      auth:
        workloadIdentity:
          clusterLocation: <region>
          clusterName: <cluster-name>
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

Same store **name** (`cloud-secrets`) on every cloud means app ExternalSecrets are portable. In a fleet, I'd ship these as `addons/secret-stores/overlays/<cloud>-<env>` and pick the overlay from an inventory field (e.g. add `cloud: aks` to `clusters/*.yaml`).

### Argo CD: SSO, RBAC, no admin

| Setting | Where | Example |
| --- | --- | --- |
| External URL | `argocd-cm` `url` | `https://argocd.example.com` |
| OIDC login | `argocd-cm` `oidc.config` (or Dex `dex.config` for GitHub/LDAP/SAML) | issuer, clientID, `clientSecret: $oidc.clientSecret` |
| Default access | `argocd-rbac-cm` `policy.default` | `role:readonly` or empty (no access) |
| Group mapping | `argocd-rbac-cm` `policy.csv` + `scopes: '[groups]'` | `g, platform-admins, role:admin` |
| Disable local admin | `argocd-cm` `admin.enabled` | `"false"` |

Docs: [user management / SSO](https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/) and [RBAC](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/).

## Hands-on

### 1. ESO end to end on kind (fake provider)

On kind there's no cloud vault, so we use ESO's `fake` provider. Everything except the store is identical to the cloud setup.

```bash
kubectl --context kind-dev apply -f - <<'EOF'
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: cloud-secrets
spec:
  provider:
    fake:
      data:
        - key: product-a/db-password
          value: correct-horse-battery-staple
EOF

kubectl --context kind-dev apply -f - <<'EOF'
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db
  namespace: product-a
spec:
  refreshInterval: 1m
  secretStoreRef:
    kind: ClusterSecretStore
    name: cloud-secrets
  target:
    name: db-credentials
  data:
    - secretKey: password
      remoteRef:
        key: product-a/db-password
EOF
```

(Applied by hand to learn the objects; in the fleet the store is a platform add-on and the ExternalSecret sits in the team's app repo.)

### 2. Write and test an RBAC policy offline

```bash
cat > /tmp/policy.csv <<'EOF'
p, role:team-a, applications, get,  fleet-platform/*-tenant-product-a, allow
p, role:team-a, applications, sync, fleet-platform/dev-tenant-product-a, allow
g, team-a, role:team-a
g, platform-admins, role:admin
EOF
argocd admin settings rbac validate --policy-file /tmp/policy.csv
argocd admin settings rbac can team-a sync applications 'fleet-platform/dev-tenant-product-a'  --policy-file /tmp/policy.csv
argocd admin settings rbac can team-a sync applications 'fleet-platform/prod-tenant-product-a' --policy-file /tmp/policy.csv
```

### 3. Turn it into config

In `bootstrap/argocd/values-prod.yaml` (Argo CD Helm chart), the relevant keys are `configs.cm` (`url`, `oidc.config`, `admin.enabled`), `configs.rbac` (`policy.csv`, `policy.default`, `scopes`) and `configs.secret.extra` or an ExternalSecret for the OIDC client secret. Once SSO works for at least two admins, set `admin.enabled: "false"` and delete `argocd-initial-admin-secret`.

## Check yourself

```bash
kubectl --context kind-dev -n product-a get externalsecret db
```

```text
NAME   STORE           REFRESH INTERVAL   STATUS         READY
db     cloud-secrets   1m                 SecretSynced   True
```

```bash
kubectl --context kind-dev -n product-a get secret db-credentials -o jsonpath='{.data.password}' | base64 -d; echo
```

```text
correct-horse-battery-staple
```

The two `rbac can` commands print `Yes` then `No`.

## Break it on purpose

**1. Rotate at the source.** Change the `value` in the fake store and re-apply. Within the refresh interval, the Kubernetes Secret changes, with no commit touching the app. (Pods only see it on restart or if they read the file mount; consider [Reloader](https://github.com/stakater/Reloader)-style tooling.)

**2. Delete the generated Secret.** `kubectl --context kind-dev -n product-a delete secret db-credentials`. ESO recreates it on the next reconcile. The ExternalSecret is the source of truth, not the Secret.

**3. Ask for a key that isn't there.** Change `remoteRef.key` to `product-a/nope`. The ExternalSecret goes `SecretSyncedError`; the existing Secret is kept. Alert on that condition in real life.

## Field notes

- In the workshop, the slowest part of this module on cloud tracks was always the identity plumbing (federated credential subject, trust policy, IAM binding), never the YAML. The subject must match `system:serviceaccount:<namespace>:<name>` exactly. When it fails, check that string first.
- Don't sync secrets to the hub "for convenience" and then copy them to spokes. Let each spoke fetch its own, with its own identity and least privilege.
- Keep a break-glass path: a documented way to re-enable the local admin (e.g. a Git change that flips `admin.enabled`) for when the IdP is down.

## Quiz

1. Which object belongs in the team's repo: ClusterSecretStore or ExternalSecret?
2. What does workload identity replace?
3. After SSO works, what two things remove the default admin login?

<details>
<summary>Answers</summary>

1. ExternalSecret. The ClusterSecretStore is platform-owned, one per cluster.
2. Long-lived cloud credentials (access keys, client secrets, JSON keys) stored in Kubernetes Secrets. The pod's ServiceAccount token is exchanged for a short-lived cloud token instead.
3. `admin.enabled: "false"` in `argocd-cm`, and deleting `argocd-initial-admin-secret`.

</details>

**Next:** [10 Going to cloud](10-going-to-cloud.md)
