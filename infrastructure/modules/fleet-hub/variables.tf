variable "argocd_namespace" {
  description = "Namespace Argo CD is installed into on the hub."
  type        = string
  default     = "argocd"
}

variable "argocd_chart_version" {
  description = "Version of the argo/argo-cd Helm chart. Renovate bumps it in a reviewable PR."
  type        = string
  # renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm
  default = "10.11.6"
}

variable "argocd_apps_chart_version" {
  description = "Version of the argo/argocd-apps Helm chart, used to create the root Application."
  type        = string
  # renovate: datasource=helm depName=argocd-apps registryUrl=https://argoproj.github.io/argo-helm
  default = "2.0.7"
}

variable "argocd_values" {
  description = "Helm values documents for Argo CD, applied in order (later ones win)."
  type        = list(string)
  default     = []
}

variable "spokes" {
  description = <<-EOT
    Workload clusters to register with Argo CD, keyed by cluster name.
    labels become labels on the Argo CD cluster Secret (ApplicationSet cluster
    generators select on them). config is the Argo CD cluster config JSON
    (credentials), see https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters
  EOT
  type = map(object({
    server = string
    labels = map(string)
    config = string
  }))
  default = {}
}

variable "root_app_manifest" {
  description = "Contents of root-app.yaml (an Argo CD Application). Applied last; it hands everything else to Git."
  type        = string
}

variable "repository" {
  description = "Optional credentials for a private fleet repo. Leave null for a public repo."
  type = object({
    url      = string
    username = string
    password = string
  })
  default   = null
  sensitive = true
}
