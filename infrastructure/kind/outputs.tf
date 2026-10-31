output "contexts" {
  description = "kubectl contexts Terraform added to your kubeconfig."
  value = merge(
    { hub = "kind-${kind_cluster.hub.name}" },
    { for name, c in kind_cluster.spoke : name => "kind-${c.name}" }
  )
}

output "registered_clusters" {
  description = "Spokes registered with Argo CD and the labels product ApplicationSets select on."
  value       = module.fleet_hub.registered_clusters
}

output "next_steps" {
  value = <<-EOT
    Argo CD UI:
      kubectl --context kind-${kind_cluster.hub.name} -n argocd port-forward svc/argocd-server 8080:443
      https://localhost:8080  (user admin; password below)
      kubectl --context kind-${kind_cluster.hub.name} -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
    Watch the fleet build itself from Git:
      kubectl --context kind-${kind_cluster.hub.name} -n argocd get applications -w
  EOT
}
