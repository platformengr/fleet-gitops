# Product deployments

Deployment config owned by product teams, one folder per product with a
Kustomize `base/` and one overlay per environment. The Argo CD Application
`<product>-<environment>` reads `<path>/<environment>` (path from
`products/<product>/product.yaml`).

In a real organisation each team keeps this in its own repository
(`checkout-deployment`); here it is a folder so the workshop needs one repo.
CODEOWNERS gives the team ownership of its folder, and changes under
`*/prod/` additionally wait for the production approval (see
[.github/workflows/production-gate.yaml](../.github/workflows/production-gate.yaml)).

The platform guarantees the namespace, quota, limits, network policy and RBAC.
The team owns everything in its folder: images, replicas, config, probes.
Kyverno (addons/kyverno-policies) and CI enforce the rules in between:
pinned image tags, requests and limits, no changes to the platform baseline.

| Change | Edit | Approval |
| --- | --- | --- |
| New version to dev | `checkout/dev/kustomization.yaml` (`newTag`) | product team |
| Promote to prod | `checkout/prod/kustomization.yaml` (`newTag`) | product team + production gate |
| Roll back | `git revert <commit>` in a pull request | same as the change |
