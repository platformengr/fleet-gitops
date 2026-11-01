# fleet-hub: everything the hub needs before Git can take over.
#
#   1. Argo CD (Helm)
#   2. One declarative cluster Secret per spoke, labelled from the inventory
#   3. Optional repository credentials
#   4. The root Application (root-app.yaml). From here on, Argo CD reads Git.
#
# Provider-agnostic: the caller configures the helm and kubernetes providers
# for the hub (kind, AKS, EKS, GKE or any existing cluster).

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = var.argocd_namespace
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  values           = var.argocd_values
  wait             = true
  timeout          = 600
}

resource "kubernetes_secret_v1" "cluster" {
  for_each = var.spokes

  metadata {
    name      = "cluster-${each.key}"
    namespace = var.argocd_namespace
    labels = merge(each.value.labels, {
      "argocd.argoproj.io/secret-type" = "cluster"
      "app.kubernetes.io/managed-by"   = "terraform"
    })
  }

  data = {
    name   = each.key
    server = each.value.server
    config = each.value.config
  }

  depends_on = [helm_release.argocd]
}

resource "kubernetes_secret_v1" "repository" {
  count = var.repository == null ? 0 : 1

  metadata {
    name      = "fleet-repo"
    namespace = var.argocd_namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
      "app.kubernetes.io/managed-by"   = "terraform"
    }
  }

  data = {
    type     = "git"
    url      = var.repository.url
    username = var.repository.username
    password = var.repository.password
  }

  depends_on = [helm_release.argocd]
}

locals {
  root = var.root_app_manifest == null ? null : yamldecode(var.root_app_manifest)
}

# The root Application is a CRD instance. kubernetes_manifest would need the
# CRD at plan time (it does not exist before Argo CD is installed), so the
# argocd-apps chart creates it instead.
resource "helm_release" "root_app" {
  count = local.root == null ? 0 : 1

  name       = "fleet-root"
  namespace  = var.argocd_namespace
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version

  values = [yamlencode({
    applications = {
      (local.root.metadata.name) = merge(local.root.spec, {
        namespace = local.root.metadata.namespace
      })
    }
  })]

  depends_on = [kubernetes_secret_v1.cluster, kubernetes_secret_v1.repository]
}
