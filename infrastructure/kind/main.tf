# Local fleet on kind: a hub plus one cluster per kind entry in clusters/*.yaml.
#
#   terraform init && terraform apply
#
# Order of events (the course calls this the bootstrap chain):
#   inventory (clusters/*.yaml) -> kind clusters -> Argo CD on the hub
#   -> cluster Secrets (labels from the inventory) -> root Application
#   -> Argo CD syncs applicationsets/ from Git and takes it from there.

locals {
  repo_root = abspath("${path.module}/../..")

  # The inventory is the single source of truth for which clusters exist.
  inventory = {
    for f in fileset("${local.repo_root}/clusters", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${local.repo_root}/clusters/${f}"))
  }
  kind_spokes = { for name, c in local.inventory : name => c if try(c.provider, "") == "kind" }
}

resource "kind_cluster" "hub" {
  name           = var.hub_name
  node_image     = var.node_image
  wait_for_ready = true
}

resource "kind_cluster" "spoke" {
  for_each = local.kind_spokes

  name           = each.key
  node_image     = var.node_image
  wait_for_ready = true

  lifecycle {
    precondition {
      # All kind clusters share the "kind" Docker network, and the API server
      # certificate is valid for <name>-control-plane, so this address is
      # reachable from the hub and stable across re-creation.
      condition     = each.value.server == "https://${each.key}-control-plane:6443"
      error_message = "clusters/${each.key}.yaml: server must be https://${each.key}-control-plane:6443 for a kind cluster."
    }
  }
}

provider "helm" {
  kubernetes = {
    host                   = kind_cluster.hub.endpoint
    client_certificate     = kind_cluster.hub.client_certificate
    client_key             = kind_cluster.hub.client_key
    cluster_ca_certificate = kind_cluster.hub.cluster_ca_certificate
  }
}

provider "kubernetes" {
  host                   = kind_cluster.hub.endpoint
  client_certificate     = kind_cluster.hub.client_certificate
  client_key             = kind_cluster.hub.client_key
  cluster_ca_certificate = kind_cluster.hub.cluster_ca_certificate
}

module "fleet_hub" {
  source = "../modules/fleet-hub"

  argocd_values = [file("${path.module}/../argocd/values-${var.argocd_profile}.yaml")]

  spokes = {
    for name, c in local.kind_spokes : name => {
      server = c.server
      labels = {
        "fleet.gitops/name"         = name
        "fleet.gitops/environment"  = c.environment
        "fleet.gitops/region"       = c.region
        "fleet.gitops/upgrade-wave" = tostring(c.upgradeWave)
      }
      # Workshop simplification: Argo CD uses the kind admin certificate.
      # Production: a scoped identity per spoke (ServiceAccount token, or
      # workload identity on AKS/EKS/GKE), see infrastructure/cloud/lib/argocd.sh.
      config = jsonencode({
        tlsClientConfig = {
          caData   = base64encode(kind_cluster.spoke[name].cluster_ca_certificate)
          certData = base64encode(kind_cluster.spoke[name].client_certificate)
          keyData  = base64encode(kind_cluster.spoke[name].client_key)
        }
      })
    }
  }

  # The course adds root-app.yaml in module 03; until then Terraform only
  # installs Argo CD and registers the clusters.
  root_app_manifest = fileexists("${local.repo_root}/root-app.yaml") ? file("${local.repo_root}/root-app.yaml") : null
  repository        = var.repository
}
