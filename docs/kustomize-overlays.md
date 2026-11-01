# Kustomize Overlays

Kustomize lets this repo reuse a base set of Kubernetes manifests and then layer environment-specific changes on top. A `kustomization.yaml` file is the instruction file that tells Kustomize which resources and patches to include.

## How To Read A Kustomize Folder

```text
base/
  kustomization.yaml       -> lists shared resources
  resource.yaml            -> plain Kubernetes YAML
overlays/dev/
  kustomization.yaml       -> includes ../../base and adds dev changes
overlays/prod/
  kustomization.yaml       -> includes ../../base and adds prod changes
```

You can render an overlay locally with `kubectl kustomize`:

```bash
kubectl kustomize addons/namespaces/overlays/dev
kubectl kustomize addons/kyverno-policies/overlays/prod
```

## Platform Namespace Example

[../addons/namespaces/base/kustomization.yaml](../addons/namespaces/base/kustomization.yaml) includes [../addons/namespaces/base/platform-namespaces.yaml](../addons/namespaces/base/platform-namespaces.yaml). That file creates shared platform Namespaces such as `observability`, `ingress-system`, `cert-manager`, and `kyverno`.

[../addons/namespaces/overlays/dev/kustomization.yaml](../addons/namespaces/overlays/dev/kustomization.yaml) and [../addons/namespaces/overlays/prod/kustomization.yaml](../addons/namespaces/overlays/prod/kustomization.yaml) both include the base and add environment labels.

Argo CD points each cluster at the overlay matching its `environment` field from [../clusters/](../clusters/). That connection is defined in [../applicationsets/platform-namespaces-appset.yaml](../applicationsets/platform-namespaces-appset.yaml).

## Kyverno Policy Example

[../addons/kyverno-policies/base/kustomization.yaml](../addons/kyverno-policies/base/kustomization.yaml) lists the guardrails every cluster gets. The base sets them to `Enforce`.

The dev overlay ([../addons/kyverno-policies/overlays/dev/kustomization.yaml](../addons/kyverno-policies/overlays/dev/kustomization.yaml)) uses a JSON patch to switch the workload rules to `Audit`, so teams can experiment in dev. The prod overlay keeps the base as is.

## Product Deployment Example

[../product-deployments/checkout/](../product-deployments/checkout/) has a `base/` and one overlay per environment. Each overlay sets the namespace, the image tag (`images:`) and per-environment differences such as replicas. Promoting a version to prod is a one-line change of `newTag` in `prod/kustomization.yaml`.

## When To Use This Pattern

Use Kustomize here when most YAML is shared and only small environment differences are needed. Use Helm here when values, templating, or a published chart is a better fit. This repo uses both: Kustomize for local policy and namespace overlays, Helm for third-party add-ons and the product namespace baseline chart.