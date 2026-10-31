# Operating model

How people work with this fleet: who owns what, how a change travels from a request to a running workload, where approvals happen, and how failures are handled.

## Ownership

| Platform team | Product team | Shared |
| --- | --- | --- |
| Cluster lifecycle ([infrastructure/](../infrastructure/), [clusters/](../clusters/)) | Application code (their own repo) | Production promotion: product decides, approval gate records it |
| Argo CD and its configuration | Deployment config ([product-deployments/\<product\>/](../product-deployments/)) | Incident response |
| Cluster registration and labels | Resource requests and limits, replicas | Capacity planning (the `size` in `product.yaml`) |
| Namespace baseline ([charts/product-namespace](../charts/product-namespace/)) | Environment-specific values | Security exceptions |
| Policies and guardrails ([addons/kyverno-policies](../addons/kyverno-policies/)) | Application health and runbooks | |
| ApplicationSet templates ([applicationsets/](../applicationsets/)) | | |
| Shared add-ons: ingress, certificates, secrets, observability | | |

[CODEOWNERS](../.github/CODEOWNERS) turns this table into review requirements. Enable branch protection on `main` with **Require a pull request**, **Require review from Code Owners** and the required checks `validate`, `plan` and `production-gate / approve`.

## The change journey

Every change, from onboarding a product to bumping an add-on, follows the same path. Each step leaves a record that links to the next.

| Step | Where | Record |
| --- | --- | --- |
| **Requested** | GitHub issue from a form ([.github/ISSUE_TEMPLATE](../.github/ISSUE_TEMPLATE/)) | Issue number |
| **Proposed** | Pull request, `Closes #<issue>` | PR, diff |
| **Validated** | `validate` check: [scripts/validate.sh](../scripts/validate.sh) | Check run |
| **Previewed** | `plan` check comments the Applications that will be added, removed or changed | PR comment |
| **Approved** | Code owner review; for prod also the `production` environment approval | Review, deployment approval |
| **Merged** | Squash merge to `main` | Commit SHA |
| **Recorded** | `deployment-record` workflow: a GitHub deployment per product environment, with PR and issue | Deployments tab, run summary |
| **Reconciled** | Argo CD syncs the commit (every ~3 minutes, or on webhook) | `scripts/trace.sh <sha>`, Argo CD history |
| **Healthy** | Argo CD health checks; Grafana logs from every cluster | Application status |

From a running Application you can walk back: the Argo CD UI links each product Application to its `product.yaml`, its config folder and its commit history (`link.argocd.argoproj.io/*` annotations), and the namespace carries the onboarding issue in `fleet.gitops/request`.

## Approvals, precisely

- **Non-production changes deploy automatically after merge.** Review by the code owners is the only gate.
- **Production changes need an explicit approval** in addition: the `production-gate` workflow detects any change that reaches prod (`product-deployments/*/prod/`, prod overlays, prod clusters, product declarations) and waits on the `production` GitHub environment. Configure it under *Settings → Environments → production → Required reviewers*.
- **Git is the audit trail.** Argo CD syncs prod automatically after merge, so the PR, its review, the environment approval and the merge commit together answer *what changed, who approved it and when*.
- **Rollback is a revert.** `git revert <sha>` in a pull request goes through the same checks; prod reverts need the same approval. Argo CD's own rollback button is for emergencies only: it disables auto-sync for that Application until Git catches up.

> **Solo learners:** GitHub does not let you approve your own pull request, but you *can* be the required reviewer of the `production` environment. That is enough to experience the gate. In a team, require one approving review as well.

## Failure drills

Each drill answers: what failed, how it was detected, who responds, how it is corrected, and how the platform prevents it next time. Course module 08 runs them hands-on.

| Scenario | Detected by | Responder | Correction | Prevention |
| --- | --- | --- | --- | --- |
| Invalid product declaration (unknown environment, typo in schema) | `validate` check on the PR | Product team | Fix the PR | Schema + `fleet_check.py`, required check |
| Unpinned image (`:latest`) | Kyverno CLI in CI; admission in prod | Product team | Pin the tag | Same policy in CI and cluster |
| App syncs before its namespace exists | Argo CD: `SyncFailed`, then retries | Nobody, it heals | Retry with backoff in `product-apps` | Baseline and app are separate Applications; retries make ordering eventual |
| Someone `kubectl scale`s or edits prod | Argo CD: `OutOfSync` | Argo CD (self-heal); platform asks why | Reverted to Git within seconds | `selfHeal: true`; change it in Git instead |
| Product team deletes the default-deny NetworkPolicy | Kyverno admission denies it | Product team (asks for a change) | PR to `products/` if the need is real | `protect-platform-baseline` policy |
| Bad release reaches prod | Health/alerts, logs in Grafana | Product team | `git revert` PR, approved through the gate | Dev first; promotion is a separate PR |
| A spoke is unreachable | Argo CD cluster connection state, Applications `Unknown` | Platform team | Restore the cluster; Argo CD resyncs on its own | Inventory + Terraform rebuild the cluster; everything else comes from Git |
| Hub lost | Argo CD UI gone | Platform team | `terraform apply`: new hub, same Git, same fleet | Hub holds no state that is not in Git |

## Runbook: where to look

```bash
# What is Argo CD doing?
kubectl --context kind-platform -n argocd get applications
kubectl --context kind-platform -n argocd get applications -l fleet.gitops/product=checkout
# Has my commit arrived everywhere?
scripts/trace.sh <sha> --selector fleet.gitops/product=checkout
# Why is an app OutOfSync / Degraded?
kubectl --context kind-platform -n argocd describe application checkout-prod
# What would this branch do to the fleet?
python3 scripts/fleet_check.py
```
