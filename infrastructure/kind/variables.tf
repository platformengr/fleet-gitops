variable "hub_name" {
  description = "Name of the hub (platform) kind cluster. Its kube context becomes kind-<hub_name>."
  type        = string
  default     = "platform"
}

variable "node_image" {
  description = "kindest/node image for every cluster. null uses the provider's default."
  type        = string
  default     = null
}

variable "argocd_profile" {
  description = "Argo CD values profile from infrastructure/argocd/: local (small, single replica) or prod (HA)."
  type        = string
  default     = "local"

  validation {
    condition     = contains(["local", "prod"], var.argocd_profile)
    error_message = "argocd_profile must be local or prod."
  }
}

variable "repository" {
  description = "Credentials for a private fleet repo (e.g. a fine-grained, read-only GitHub token). Leave null for a public repo. Pass via TF_VAR_repository, never commit it."
  type = object({
    url      = string
    username = string
    password = string
  })
  default   = null
  sensitive = true
}
