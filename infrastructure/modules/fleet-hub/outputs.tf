output "argocd_namespace" {
  value = var.argocd_namespace
}

output "registered_clusters" {
  description = "Cluster Secrets created on the hub, with the labels ApplicationSets select on."
  value       = { for k, s in kubernetes_secret_v1.cluster : k => s.metadata[0].labels }
}

output "root_application" {
  value = local.root == null ? null : local.root.metadata.name
}
