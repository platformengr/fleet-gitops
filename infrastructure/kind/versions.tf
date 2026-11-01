terraform {
  required_version = ">= 1.6"
  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.11"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }

  # Workshop simplification: local state in infrastructure/kind/ (git-ignored).
  # In production use a remote backend (S3, GCS, azurerm, Terraform Cloud) and
  # apply from CI after review, never from a laptop.
}
