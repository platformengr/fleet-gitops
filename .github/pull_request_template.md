## What and why

<!-- One or two sentences. Link the issue so the change journey is traceable: -->
Closes #

## Area

- [ ] Infrastructure (`infrastructure/`, Terraform) — applied by the platform team after merge
- [ ] Cluster inventory (`clusters/`)
- [ ] Platform ApplicationSets, add-ons or policies
- [ ] Product onboarding or change (`products/`)
- [ ] Product deployment config (`product-deployments/`)
- [ ] Docs only

## Checks

- [ ] `scripts/validate.sh` passes locally (CI runs it too)
- [ ] The **fleet plan** comment shows only the Applications I expect to be added, removed or changed
- [ ] If this reaches **prod**, I know the `production-gate` approval is needed and who gives it
- [ ] Rollback is a revert of this pull request (or explained below)

## Removing things

- [ ] Not applicable
- [ ] I understand that removing an environment from a product, or deleting `product.yaml`, deletes those Applications and their workloads (the namespace is kept)
