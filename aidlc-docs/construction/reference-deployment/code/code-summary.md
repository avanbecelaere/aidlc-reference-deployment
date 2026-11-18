# Code Summary: reference-deployment

Generated 2026-11-18 under `aidlc-docs/construction/plans/reference-deployment-code-generation-plan.md`, which was approved. Nothing has been committed or pushed. Nothing has been built or run, apart from `terraform init -backend=false` and `providers lock`, which produced the lock file. Build and Test is the next stage.

## Files

### Created
| Path | Purpose | Traces to |
|---|---|---|
| `app/Dockerfile` | nginx-unprivileged, pinned by digest, serving one static file on 8080 | FR-1, NFR-4, NFR-5 |
| `app/index.html` | The fixed response body | FR-1.1 |
| `app/.dockerignore` | Keeps the build context to the two files | FR-1.3 |
| `infra/versions.tf` | Terraform `>= 1.10`, AWS `~> 6.0`, empty `backend "s3" {}` | FR-6.1, FR-6.2 |
| `infra/providers.tf` | `default_tags` with `project`. Region comes from the environment. | FR-6.4 |
| `infra/variables.tf` | Inputs and validation. `operator_cidr` must be a single `/32`. | FR-6.5, NFR-3 |
| `infra/network.tf` | VPC, 2 public subnets, IGW, routes, security group, ingress 8080 from `/32`, egress 443 | FR-2, ID §2 |
| `infra/ecr.tf` | Repository: immutable tags, scan on push, `force_delete` | FR-3, Q4 |
| `infra/iam.tf` | Execution role with boundary, source-account trust condition, managed policy | FR-5, ID §4 |
| `infra/ecs.tf` | Log group, cluster, task definition (X86_64), service (public IP, circuit breaker) | FR-4, Q3, ID §5 |
| `infra/outputs.tf` | Cluster, service, repository URL, log group | FR-6.6 |
| `infra/backend.hcl.example` | Placeholders only | FR-6.2 |
| `infra/.terraform.lock.hcl` | `hashicorp/aws` 6.73.0, hashes for linux and darwin on amd64 and arm64 | FR-6.1 |
| `infra/tests/validation.tftest.hcl` | 6 cases: valid `/32` accepted; `/0`, `/24`, `0.0.0.0/32`, malformed CIDR and bad project rejected | NFR-3 (approved addition) |
| `infra/tests/invariants.tftest.hcl` | 12 assertions on the security and correctness invariants | approved addition |
| `.github/workflows/pr-checks.yml` | No credentials: id grep, fmt, init, validate, test, docker build | FR-7 |
| `.github/workflows/deploy.yml` | OIDC, masking, `backend.hcl`, ECR bootstrap, build and push, scan summary, plan, apply, stable-on-this-SHA check, address, denial probe | FR-8, Q2, Q3, Q4 |
| `.github/workflows/destroy.yml` | Typed confirmation, destroy, INACTIVE task definition cleanup, plan must report no changes, tag query | FR-9 |
| `docs/deploy.md` | Operator runbook | FR-10.1 |

### Modified
| Path | Change |
|---|---|
| `docs/prerequisites.md` | §4: names the boundary, points to the API list, flags the `TagRole`/`DeleteRole` condition gap. §5: adds the `OPERATOR_CIDR` secret. Removal: deletes the secret, and destroy must run before removal. |
| `README.md` | Adds `docs/deploy.md` to "Start here", updates the tree, records the plan-on-PR deviation (FR-7) |

### Unchanged
`docs/vision.md`, `.github/workflows/verify-oidc.yml`, `.gitignore`, `CLAUDE.md`, `.aidlc-rule-details/`.

## Resolved Pins (Step 1)
| Item | Value | Source |
|---|---|---|
| `actions/checkout` | v7.0.1, `3d3c42e5aac5ba805825da76410c181273ba90b1` | GitHub releases/latest, and the tag ref (a lightweight tag pointing at a commit) |
| `hashicorp/setup-terraform` | v4.0.1, `dfe3c3f87815947d99a8997f908cb6525fc44e9e` | GitHub releases/latest, and the tag ref |
| `aws-actions/configure-aws-credentials` | v6.3.0, `e1253824e5c10ff9df46874f81ed3ec929e19cfd` | Reused from `verify-oidc.yml`; checked against the tag ref |
| Terraform (CI) | 1.17.2 | HashiCorp checkpoint API. The local workstation has 1.16.3. |
| Base image | `nginxinc/nginx-unprivileged:1.30.6-alpine3.24@sha256:f5116ed4606f3eb015dd4a8e28cb9b351476dc0ad4bc6e9f93b19cec130cdf03` | Docker Hub. This is `stable-alpine` as of 2026-10-19. The multi-arch index includes linux/amd64. |
| AWS provider | 6.73.0 | Resolved by `terraform init` against `~> 6.0` |

## Implementation Choices Not Spelled Out in the Design
These are refinements within the approved design, listed so they can be reviewed:

1. **Branch guard.** It is a failing first step, not a job-level `if`. A skipped job reads as success; a failed step says why. ID §7.2 said "fails it early with a clear message".
2. **Missing-secret guard.** Deploy fails at once with a clear message if `OPERATOR_CIDR` is unset, instead of a Terraform variable error later.
3. **Stable on this commit.** After `services-stable`, deploy also checks that the service's image ends in `:<this SHA>`. With circuit-breaker rollback, a failed deployment returns the service to "stable" on the **old** image, and the wait alone would pass. This closes that hole.
4. **ECR URI.** It comes from `aws ecr describe-repositories`, not `terraform output`. Outputs are not reliably set after a `-target` apply.
5. **Destroy placeholder CIDR.** Destroy uses `secrets.OPERATOR_CIDR || '192.0.2.1/32'` (TEST-NET-1), so teardown still works if the secret was removed first.
6. **Mock account id.** The test mocks use `account_id = "mock-account"`, not a 12-digit number, so the PR id grep passes.
7. **Extra data sources.** `aws_region` (for `awslogs-region`) and `aws_iam_policy_document` (for the trust policy) were added, alongside the data sources the design named.
8. **Checkout.** Uses `persist-credentials: false`, so the GitHub token is not left in the runner's git config.

## Static Self-check (Step 17)
| Check | Result |
|---|---|
| 12-digit numbers, `arn:aws:iam::<digits>`, `tfstate-<digits>` in new, changed and docs files | None found |
| IPv4 literals outside `10.0.x`, `0.0.0.0`, `203.0.113.x`, `192.0.2.x` | None found |
| Every `uses:` pinned to a 40-character SHA | Yes (3 distinct actions) |
| Every workflow declares `permissions` | Yes (4 of 4) |
| builder-security sweep | `0.0.0.0/0` appears only as the IGW route destination and the 443 egress peer. The ingress peer is only `var.operator_cidr`, validated as a `/32`. nginx's in-container listener is bounded by the security group. No other listeners or `ports:` mappings. |

## Known Limitations
- The deploy role's permissions are hand-made, and they have not been tested against this code. The first live apply may hit `AccessDenied`. The likeliest is `iam:TagRole`; see `docs/prerequisites.md` §4.
- `terraform test` and `validate` have not run yet; they run in Build and Test. The mock provider's handling of `task_role_arn == null` is the assertion most likely to need adjusting.
- The task's public IP changes on every deployment. This is accepted (vision §3).
