# 10 Going to cloud

**Goal:** run the same fleet on AKS, EKS or GKE, and register spokes with short-lived, identity-based credentials instead of long-lived tokens.
**Time:** 60-90 minutes (most of it waiting for the cloud)

**You'll touch:** [bootstrap/aks/](../bootstrap/aks/), [bootstrap/eks/](../bootstrap/eks/), [bootstrap/gke/](../bootstrap/gke/), [bootstrap/lib/argocd.sh](../bootstrap/lib/argocd.sh), [clusters/*.yaml](../clusters/)

> Cloud clusters cost money while they run. Read `--dry-run` output first, and run `down.sh` when you're done for the day.

## Concepts

### What changes from kind, and what doesn't

| Stays the same | Changes |
| --- | --- |
| `applicationsets/`, `addons/`, `charts/`, `requests/` | how clusters are created (provider CLI) |
| `clusters/*.yaml` shape | `server` values (managed API endpoints), `lokiEndpoint` (a real route) |
| the root app | **how the hub authenticates to spokes** |
| | network path from hub to spoke APIs |

That's the payoff of modules 03-09: going to cloud is mostly an inventory change plus identity.

### Spoke credentials: from tokens to identity

In module 03 the cluster Secret held a ServiceAccount bearer token: long-lived and cluster-admin. In cloud, the hub's Argo CD pods get a **cloud identity** through workload identity, and Argo CD calls `argocd-k8s-auth` (shipped in the Argo CD image) to mint a short-lived token for each spoke.

```text
 hub: argocd-application-controller pod
   ServiceAccount token (projected)
        |  workload identity federation
        v
   cloud identity (Entra app / IAM role / Google SA)
        |  argocd-k8s-auth <azure|aws|gcp>  -> short-lived token
        v
   spoke API server  -- authorizes via cloud RBAC / access entry / K8s RBAC
```

The Secret is still a declarative cluster Secret (label `argocd.argoproj.io/secret-type: cluster`). Only `config` changes, and it no longer contains anything secret.

Grant the identity on **both** hub components that talk to clusters: `argocd-application-controller` and `argocd-server` (the API/UI also lists resources and runs actions).

#### On AKS (Azure Workload Identity)

Hub prerequisites: OIDC issuer + workload identity enabled on the hub, a user-assigned managed identity (or app registration) with a federated credential for each Argo CD ServiceAccount, the ServiceAccounts annotated with `azure.workload.identity/client-id`, and the pods labeled `azure.workload.identity/use: "true"`. Spokes: Entra ID integration with Azure RBAC (or a Kubernetes RBAC binding) granting that identity access.

```yaml
stringData:
  name: prod
  server: https://<prod-api-fqdn>:443
  config: |
    {
      "execProviderConfig": {
        "command": "argocd-k8s-auth",
        "args": ["azure"],
        "apiVersion": "client.authentication.k8s.io/v1beta1",
        "env": {
          "AAD_ENVIRONMENT_NAME": "AzurePublicCloud",
          "AZURE_CLIENT_ID": "<identity-client-id>",
          "AZURE_TENANT_ID": "<tenant-id>",
          "AZURE_FEDERATED_TOKEN_FILE": "/var/run/secrets/azure/tokens/azure-identity-token",
          "AZURE_AUTHORITY_HOST": "https://login.microsoftonline.com/",
          "AAD_LOGIN_METHOD": "workloadidentity"
        }
      },
      "tlsClientConfig": { "insecure": false, "caData": "<base64 CA>" }
    }
```

#### On EKS (IRSA, or EKS Pod Identity)

Argo CD has first-class AWS support: `awsAuthConfig` makes it call `argocd-k8s-auth aws` for you. The hub's Argo CD ServiceAccounts get an IAM role (IRSA annotation `eks.amazonaws.com/role-arn`, or a Pod Identity association on newer Argo CD versions); that role may assume a per-spoke deployer role. Each spoke grants the deployer role access with an **EKS access entry** (preferred over the legacy `aws-auth` ConfigMap).

```yaml
stringData:
  name: prod
  server: https://<id>.gr7.<region>.eks.amazonaws.com
  config: |
    {
      "awsAuthConfig": {
        "clusterName": "<prod-cluster-name>",
        "roleARN": "arn:aws:iam::<account-id>:role/<argocd-deployer>"
      },
      "tlsClientConfig": { "insecure": false, "caData": "<base64 CA>" }
    }
```

#### On GKE (Workload Identity)

The hub's Argo CD Kubernetes ServiceAccounts are bound to a Google service account (annotation `iam.gke.io/gcp-service-account`, plus a `roles/iam.workloadIdentityUser` binding). On each spoke's project, that Google SA needs a role that lets it get cluster credentials (e.g. `roles/container.clusterViewer`) plus Kubernetes RBAC on the spoke, or a broader GKE role such as `roles/container.developer` if you accept that.

```yaml
stringData:
  name: prod
  server: https://<prod-endpoint>
  config: |
    {
      "execProviderConfig": {
        "command": "argocd-k8s-auth",
        "args": ["gcp"],
        "apiVersion": "client.authentication.k8s.io/v1beta1"
      },
      "tlsClientConfig": { "insecure": false, "caData": "<base64 CA>" }
    }
```

Exact env vars and IAM role names move between versions. The source of truth is the Argo CD [declarative setup: clusters](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters) page (sections on EKS, AKS and GKE). If something here disagrees with it, believe the docs.

### Private API endpoints

Private spoke APIs are the right default for prod, but the hub must reach them:

- **Same network or peered networks** (VNet peering / VPC peering / Shared VPC), plus private DNS so the hub resolves the private endpoint name (AKS private clusters use a private DNS zone; link it to the hub's VNet).
- **Allow-list the hub** in the control plane firewall: AKS authorized IP ranges, EKS endpoint security groups / public access CIDRs, GKE authorized networks.
- **Or invert the direction**: run an agent on each spoke that pulls from a control plane (see the [argocd-agent](https://github.com/argoproj-labs/argocd-agent) project). Worth evaluating if your spokes can't be reached at all.

## Hands-on

Pick your cloud. The flow is the same for all three.

```bash
cd bootstrap/<cloud>          # aks | eks | gke
cp env.example env
$EDITOR env                   # PREFIX, REGION, K8S_VERSION, NODE_SIZE, NODE_COUNT_MIN/MAX, REPO_URL, ...
./up.sh --dry-run | less      # read every command it will run
./up.sh
```

### On AKS

Needs `az login` and a subscription selected (`az account set -s <id>`). The script creates the hub, dev and prod clusters with workload identity and network policy enabled, installs Argo CD, registers spokes and updates `clusters/*.yaml`. See [bootstrap/aks/up.sh](../bootstrap/aks/up.sh).

### On EKS

Needs `aws sts get-caller-identity` to work and `eksctl`. Cluster creation takes the longest here (often 15+ minutes per cluster). See [bootstrap/eks/up.sh](../bootstrap/eks/up.sh).

### On GKE

Needs `gcloud auth login`, a project (`gcloud config set project <id>`) and the GKE API enabled. See [bootstrap/gke/up.sh](../bootstrap/gke/up.sh).

### After up.sh (all clouds)

```bash
git diff clusters/            # new server values
git commit -am "inventory: <cloud> endpoints" && git push
```

Then revisit two kind-specific shortcuts:

1. `lokiEndpoint`: replace the NodePort from module 07 with a real route (internal load balancer or private ingress on the hub).
2. `metrics-server` has `--kubelet-insecure-tls` for kind. Managed clusters usually don't need it; remove it per environment.

Teardown:

```bash
./down.sh
```

## Check yourself

```bash
kubectl --context <hub-context> -n argocd get secret -l argocd.argoproj.io/secret-type=cluster \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
argocd cluster list
```

Two spokes, `STATUS Successful` once apps sync. And:

```bash
kubectl --context <hub-context> -n argocd get secret -l argocd.argoproj.io/secret-type=cluster \
  -o jsonpath='{.items[*].data.config}' | base64 -d | grep -c bearerToken
```

```text
0
```

No bearer tokens in your cluster Secrets.

## Break it on purpose

**1. Remove the permission, not the Secret.** Revoke the spoke-side grant for the hub identity (delete the Azure role assignment / EKS access entry / GKE IAM binding) for `dev`. `argocd cluster list` shows dev failing with an authorization error within minutes; nothing changed in Git. Restore it. This is what an IAM cleanup gone wrong looks like.

**2. Read the dry run as a reviewer.** Run `./up.sh --dry-run` and find the lines that enable workload identity, set the node pool autoscaling range and choose the Kubernetes version. If you can't find them, you can't review them in a PR either.

## Field notes

- In the workshop, cloud tracks lost the most time on the hub-to-spoke network path, not on Argo CD. Test it before blaming Argo CD: `kubectl run -it --rm nettest --image=curlimages/curl -- curl -sk https://<spoke-api>/version` from the hub.
- Name cloud resources with a `PREFIX` and tag them. Forgotten clusters are the most expensive part of any cloud workshop.
- Keep the identity setup (federated credentials, roles, access entries) in IaC next to the cluster definitions. Argo CD can't bootstrap the identity it needs to log in.

## Quiz

1. What in the cluster Secret changes between kind and cloud?
2. Which two Argo CD components need the cloud identity?
3. A spoke has a private API endpoint. Name two ways the hub can still manage it.

<details>
<summary>Answers</summary>

1. The `config` field: from a bearer token to an exec provider (`argocd-k8s-auth azure|gcp`) or `awsAuthConfig`. `name`, `server` and the cluster label stay.
2. `argocd-application-controller` and `argocd-server`.
3. Network peering/shared network with private DNS and an allow-listed hub; or an agent on the spoke that pulls (e.g. argocd-agent).

</details>

**Next:** [11 Production checklist](11-production-checklist.md)
