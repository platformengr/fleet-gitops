# Infrastructure

Everything that has to exist before Git can take over: clusters, Argo CD, cluster registration and the root Application. Owned by the platform team.

```text
infrastructure/
├── kind/               Terraform root: local fleet (hub + every provider: kind cluster in clusters/)
├── modules/fleet-hub/  Terraform module: Argo CD, cluster Secrets, root app on any hub cluster
├── argocd/             Argo CD Helm values: local (small) and prod (HA)
└── cloud/              Scripts for AKS, EKS, GKE (simplified, imperative; see below)
```

## Local fleet with kind

```bash
cd infrastructure/kind
terraform init
terraform plan      # read it: 3 clusters, Argo CD, 2 cluster Secrets, 1 root app
terraform apply
terraform output next_steps
```

What happens, in order:

1. Terraform reads [`clusters/*.yaml`](../clusters/). Every entry with `provider: kind` becomes a kind cluster, plus the hub (`platform`). Contexts: `kind-platform`, `kind-dev`, `kind-prod`.
2. Argo CD is installed on the hub with [argocd/values-local.yaml](argocd/values-local.yaml).
3. Each spoke gets a declarative Argo CD cluster Secret. Its labels come from the inventory: `fleet.gitops/environment`, `fleet.gitops/region`, `fleet.gitops/upgrade-wave`, `fleet.gitops/name`. The product ApplicationSets select clusters by these labels.
4. The root Application from [root-app.yaml](../root-app.yaml) is created. Argo CD syncs [applicationsets/](../applicationsets/) from your repo and builds the rest of the fleet from Git.

Kind spokes use `server: https://<name>-control-plane:6443`: every kind node joins the `kind` Docker network, so the hub reaches spokes by container name, and the API server certificate is valid for that name. The address survives re-creating a cluster, so the inventory never needs editing after a rebuild.

### Add a cluster

1. Open an issue with the **Add or change a cluster** form.
2. Add `clusters/<name>.yaml` (copy `dev.yaml`, change `name`, `server`, `environment`, `upgradeWave`) in a pull request. CI validates it; the plan comment lists the Applications the cluster will receive.
3. After merge: `terraform apply` creates and registers it. ApplicationSets do the rest, including every product with that environment.

### Tear down

```bash
terraform destroy      # or: kind delete clusters platform dev prod
```

Git still holds the fleet. `terraform apply` rebuilds it, and Argo CD restores every add-on and product: the disaster-recovery drill in course module 08.

### Private repository

Argo CD needs read access. Create a fine-grained token with read-only *Contents* on the repo and pass it without committing it:

```bash
export TF_VAR_repository='{"url":"https://github.com/<you>/<repo>.git","username":"git","password":"<token>"}'
terraform apply
```

## Simplified on purpose

> **Workshop simplification.** In production, infrastructure usually lives in its own repository (`infrastructure-live`), Terraform state is remote (S3, GCS, Azure Storage or Terraform Cloud), `terraform plan` runs on the pull request, and `terraform apply` runs from CI after approval with short-lived cloud credentials (OIDC). The CI here only runs `fmt` and `validate`, because kind clusters live on your laptop.

> **Workshop simplification.** Argo CD talks to kind spokes with the kind admin certificate. In production each spoke trusts a scoped identity: a ServiceAccount token at minimum, workload identity on managed Kubernetes. [cloud/lib/argocd.sh](cloud/lib/argocd.sh) shows both.

## Existing and cloud clusters

The [fleet-hub module](modules/fleet-hub/) does not care where the hub runs. To use it with clusters you already have (or that your cloud Terraform creates), configure the `helm` and `kubernetes` providers for the hub and pass each spoke's server, labels and Argo CD `config` JSON:

```hcl
module "fleet_hub" {
  source            = "../modules/fleet-hub"
  argocd_values     = [file("../argocd/values-prod.yaml")]
  root_app_manifest = file("../../root-app.yaml")
  spokes = {
    prod-eu = {
      server = "https://prod-eu.example.com"
      labels = { "fleet.gitops/environment" = "prod", "fleet.gitops/region" = "eu",
                 "fleet.gitops/name" = "prod-eu", "fleet.gitops/upgrade-wave" = "1" }
      config = jsonencode({ execProviderConfig = { command = "argocd-k8s-auth", args = ["azure"],
                 apiVersion = "client.authentication.k8s.io/v1beta1" },
                 tlsClientConfig = { caData = "<base64 CA>" } })
    }
  }
}
```

### Scripted cloud tracks

[cloud/](cloud/) contains scripts that create a hub, dev and prod on **AKS**, **EKS** or **GKE** with sensible defaults (managed identity, OIDC issuer, autoscaling pools), install Argo CD (HA profile), register the spokes and write `clusters/dev.yaml` and `clusters/prod.yaml`:

```bash
cp infrastructure/cloud/aks/env.example infrastructure/cloud/aks/env    # edit PREFIX, REGION, ...
infrastructure/cloud/aks/up.sh --dry-run    # prints every command, changes nothing
infrastructure/cloud/aks/up.sh
git diff clusters/                          # then commit the inventory in a pull request
infrastructure/cloud/aks/down.sh            # deletes everything up.sh created
```

> **Workshop simplification.** These scripts are imperative so that a learner can read every command. For a real platform, replace them with Terraform modules for your cloud (for example the official AKS, EKS and GKE modules) feeding the fleet-hub module above. Course module 11 walks through the move.
