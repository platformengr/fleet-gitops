# Cluster inventory

One YAML file per workload cluster. The platform team owns this folder, and it is the single source of truth for which clusters exist:

- **Terraform** ([infrastructure/kind](../infrastructure/kind/)) creates every `provider: kind` cluster and registers it with Argo CD. The registration (an Argo CD cluster Secret) gets labels from these fields.
- **Platform ApplicationSets** read these files directly to install add-ons, policies and log agents per cluster.
- **Product ApplicationSets** select clusters by the labels, so `environment: prod` here decides where every product's prod environment runs.

## Fields

| Field | Used by | Meaning |
| --- | --- | --- |
| `name` | Terraform, Application names, logs | Stable cluster name, equal to the file name |
| `provider` | Terraform | `kind` (created by infrastructure/kind), or `aks`/`eks`/`gke`/`external` (created elsewhere) |
| `server` | Argo CD destination | API server URL as the hub reaches it. kind: `https://<name>-control-plane:6443` |
| `environment` | Overlays, label `fleet.gitops/environment` | Which product environments land here; must have `addons/*/overlays/<environment>` |
| `upgradeWave` | Label `fleet.gitops/upgrade-wave` | Order for platform upgrades: wave 0 first |
| `region` | Label `fleet.gitops/region` | For selection and visibility |
| `lokiEndpoint` | Alloy log agent | Where the cluster ships logs |

`scripts/fleet_check.py` (CI) checks required fields, unique names and servers, and that overlays exist for the environment.

## Add a cluster

1. Open an **Add or change a cluster** issue.
2. Copy `dev.yaml` to `<name>.yaml`; set `name`, `server`, `environment`, `upgradeWave`, `region`.
3. Open a pull request. The `plan` comment lists every Application the new cluster will receive, including every product that has its environment.
4. After merge, `terraform apply` in `infrastructure/kind` creates and registers it.
