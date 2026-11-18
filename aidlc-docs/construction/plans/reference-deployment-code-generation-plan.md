# Code Generation Plan: reference-deployment

**This plan is the single source of truth for Code Generation Part 2.** Steps run in order. Each one is checked off as soon as it is done.

## Unit Context

| Item | Value |
|---|---|
| Unit | `reference-deployment`, the only unit |
| Project type | Greenfield |
| Workspace root | `/local/home/avanbece/repos/aidlc-reference-deployment` |
| Design inputs | `requirements.md`, `infrastructure-design.md`, `deployment-architecture.md` (all approved) |
| Stories | None, because User Stories was skipped. Traceability is to requirement ids (FR-x, NFR-x) and infrastructure design sections (ID §x). |
| Dependencies | Hand-made and pre-existing, referenced only, never created (constraint 1): the state bucket, the OIDC provider, the deploy role and its policy, the boundary `aidlc-demo-task-boundary`, and the repository variables `AWS_DEPLOY_ROLE_ARN` and `AWS_REGION`. The operator still has to add one: the new repository secret `OPERATOR_CIDR`. |
| Interfaces | `GET /` on TCP 8080 returns a fixed body. No other contract exists. |
| Database entities | None |

### Code locations
The default greenfield `src/`/`tests/`/`config/` layout is replaced by the layout the infrastructure design approved (ID §6), because this unit is infrastructure plus one static container:

```text
app/                    Dockerfile, index.html, .dockerignore
infra/                  Terraform root module, lock file, backend.hcl.example
infra/tests/            terraform test files (offline, mock provider)
.github/workflows/      pr-checks.yml, deploy.yml, destroy.yml
docs/                   deploy.md (new); prerequisites.md (updated)
README.md               updated
aidlc-docs/construction/reference-deployment/code/   markdown summary only
```

Nothing under `aidlc-docs/` is code. Existing files that stay unchanged: `docs/vision.md` (the input), `.github/workflows/verify-oidc.yml`, `CLAUDE.md` and `.aidlc-rule-details/`.

**No commits or pushes.** Files are written to the working tree only. Committing is your decision.

### One addition beyond the approved design (included for your approval)
Step 8 adds **`terraform test` files** that run offline against a mock AWS provider. Step 10 adds `terraform test` to `pr-checks.yml`, which was not listed in ID §7.1. It asserts the security-relevant invariants:
- the `/32`-only ingress;
- `assign_public_ip = true`;
- X86_64;
- immutable tags and scan on push;
- the circuit breaker.

It needs no credentials and no new action. If you decline it, I drop steps 8 and the test line from step 10.

---

## Steps

### Step 1: Resolve the pins (read-only network lookups)
- [x] Get the full commit SHA of the latest release of `actions/checkout`.
- [x] Get the full commit SHA of the latest release of `hashicorp/setup-terraform`.
- [x] Find the latest stable Terraform 1.x version, which must be at least 1.10.
- [x] Find the current `nginxinc/nginx-unprivileged` stable Alpine tag and its multi-arch index digest. Confirm the image includes a `linux/amd64` entry.
- [x] Reuse the `aws-actions/configure-aws-credentials` pin `e1253824e5c10ff9df46874f81ed3ec929e19cfd` (v6.3.0) from `verify-oidc.yml`.

Traceability: constraint 3, NFR-4. Each resolved value and its source is recorded in the step 16 summary.

### Step 2: Container (`app/`)
- [x] `app/Dockerfile`:
  - `FROM nginxinc/nginx-unprivileged:<tag>@sha256:<digest>`;
  - copy `index.html` into `/usr/share/nginx/html/`;
  - `EXPOSE 8080`;
  - the image's non-root user is left in place, with no `USER root`.
- [x] `app/index.html`: one fixed line of text.
- [x] `app/.dockerignore`: only `Dockerfile` and `index.html` go into the build context.

Traceability: FR-1.1 to FR-1.3, NFR-5, ID §8.

### Step 3: Terraform foundation
- [x] `infra/versions.tf`: `required_version = ">= 1.10"`, `hashicorp/aws ~> 6.0`, and an empty `backend "s3" {}`.
- [x] `infra/providers.tf`: `provider "aws"` with `default_tags { project = var.project }`. No region argument; it comes from `AWS_REGION`.
- [x] `infra/variables.tf`: `project`, `vpc_cidr`, `operator_cidr`, `image_tag` and `permissions_boundary_name`, with the validations in ID §2 and §6.

Traceability: FR-6.1 to FR-6.5, constraint 2, NFR-3.

### Step 4: Network (`infra/network.tf`)
- [x] The AZ data source, with the filters from ID §2.
- [x] The VPC, two public subnets, the internet gateway, the route table and its two associations.
- [x] The security group, plus two separate rules: ingress TCP 8080 from `var.operator_cidr`, and egress TCP 443 to `0.0.0.0/0`.

Traceability: FR-2.1 to FR-2.5, ID §2.

### Step 5: Registry and IAM (`infra/ecr.tf`, `infra/iam.tf`)
- [x] The ECR repository: `IMMUTABLE` tags, `scan_on_push = true`, `force_delete = true`, AES256.
- [x] The caller identity and partition data sources.
- [x] The execution role `${var.project}-task-execution`: trusted by `ecs-tasks.amazonaws.com` with an `aws:SourceAccount` condition, and the permissions boundary ARN built from `permissions_boundary_name`.
- [x] Attach `AmazonECSTaskExecutionRolePolicy` to the role.

Traceability: FR-3, FR-5, ID §3 and §4.

### Step 6: Compute and outputs (`infra/ecs.tf`, `infra/outputs.tf`)
- [x] The log group `/ecs/${var.project}`, with 1-day retention.
- [x] The cluster, with Container Insights explicitly disabled.
- [x] The task definition, as specified in ID §5: Fargate, `awsvpc`, 256/512, LINUX/X86_64, the execution role, no task role, port 8080, and `awslogs`.
- [x] The service, as specified in ID §5: `desired_count = 1`, both subnets, the security group, **`assign_public_ip = true`**, the circuit breaker with rollback, tag propagation, and `wait_for_steady_state = false`.
- [x] The outputs `cluster_name`, `service_name`, `ecr_repository_url` and `log_group_name`.

Traceability: FR-4, FR-6.6, ID §5.

### Step 7: Backend example
- [x] `infra/backend.hcl.example`, with placeholders only, as in ID §6. The existing `.gitignore` already allows it through with `!backend.hcl.example`.

Traceability: FR-6.2, FR-6.3, constraint 2.

### Step 8: Terraform tests (`infra/tests/`), the addition above
- [x] `infra/tests/validation.tftest.hcl`. It uses `mock_provider "aws"` and runs `command = plan` with these cases:
  - a valid `/32` is accepted;
  - `0.0.0.0/0` is rejected;
  - a `/24` is rejected;
  - `0.0.0.0/32` is rejected;
  - a malformed CIDR is rejected;
  - a bad `project` value is rejected.
- [x] `infra/tests/invariants.tftest.hcl`. It uses `mock_provider "aws"` with mock data for the AZs, caller identity and partition, plus `command = plan`. It asserts:
  - the ingress port is 8080 and its CIDR equals the input;
  - egress is port 443 only;
  - `assign_public_ip` is true;
  - `cpu_architecture` is `X86_64`;
  - ECR is `IMMUTABLE` with `scan_on_push`;
  - the circuit breaker is enabled with rollback;
  - no `task_role_arn` is set;
  - log retention is 1 day.

Traceability: NFR-3, FR-2.4, FR-3.1, FR-4.2, FR-4.3, FR-5.1, Q3, Q4.

### Step 9: Provider lock file
- [x] Run `terraform -chdir=infra init -backend=false`, then `terraform -chdir=infra providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64 -platform=darwin_amd64`. This writes `infra/.terraform.lock.hcl`, which gets committed.
- [x] The local `.terraform/` directory stays gitignored.

Traceability: FR-6.1. This step needs Terraform on this workstation. If it is missing, I'll stop and tell you rather than install it.

### Step 10: `.github/workflows/pr-checks.yml`
- [x] `on: pull_request`, with `permissions: contents: read`.
- [x] Steps:
  1. checkout;
  2. the 12-digit account-id grep over tracked files;
  3. setup-terraform, with the version pinned and `terraform_wrapper: false`;
  4. `fmt -check -recursive`;
  5. `init -backend=false`;
  6. `validate`;
  7. `terraform test`;
  8. `docker build --platform linux/amd64 app/`.

Traceability: FR-7, NFR-1, ID §7.1.

### Step 11: `.github/workflows/deploy.yml`
- [x] `workflow_dispatch`, with `id-token: write` and `contents: read`.
- [x] The concurrency group `aidlc-demo-infra`, which never cancels a run in progress.
- [x] A guard that requires the `main` ref.
- [x] The job environment from ID §7.2.
- [x] Steps 1 to 14 exactly as in ID §7.2: assume the role, mask the account id, write `backend.hcl`, init, the targeted ECR apply, ECR login, build and push unless the tag exists, the non-gating scan summary, plan, apply the saved plan, wait for stable with stopped-task reasons on failure, find the public IP, and the runner denial probe.

Traceability: FR-8, NFR-2, Q2, Q3, Q4, ID §7.2.

### Step 12: `.github/workflows/destroy.yml`
- [x] `workflow_dispatch` with a required `confirm` input, the same permissions and concurrency group, and a guard that requires the `main` ref and `confirm == 'aidlc-demo'`.
- [x] Steps exactly as in ID §7.3: the shared setup, destroy, deleting INACTIVE task definitions, a `plan -detailed-exitcode` that must return 0, and the tag query.

Traceability: FR-9, NFR-7, ID §7.3.

### Step 13: `docs/deploy.md` (new runbook)
- [x] Before the first run:
  - add the `OPERATOR_CIDR` secret;
  - check the deploy-role policy against the ID §4 checklist, including the `TagRole`/`DeleteRole` condition risk.
- [x] Deploy: run the workflow, read the service address from the log, `curl` from the operator machine, and know what the denial probe means.
- [x] Local use (optional): `backend.hcl` from the example, then `terraform init -backend-config=backend.hcl`.
- [x] Teardown: run the destroy workflow, read its output, then the manual removal in `docs/prerequisites.md`, and record the verification.
- [x] Troubleshooting:
  - the image-pull failure when there is no public IP;
  - `AccessDenied` from the deploy role;
  - an immutable tag on a re-run.

Traceability: FR-10.1, NFR-8, success criterion 4.

### Step 14: Update `docs/prerequisites.md`
- [x] Name the boundary policy `<PROJECT_TAG>-task-boundary` in §4.
- [x] Add §5 "GitHub repository": `gh secret set OPERATOR_CIDR`, as a secret and not a variable, because the value is masked in logs.
- [x] Point to the deploy-role action checklist in the infrastructure design.
- [x] Add `OPERATOR_CIDR` to the Removal steps.
- [x] Placeholders only.

Traceability: FR-10.2, NFR-1.

### Step 15: Update `README.md`
- [x] Add `docs/deploy.md` to the "Start here" table.
- [x] Update the "What is in here" tree with `app/`, `infra/` and the workflows.
- [x] State the accepted deviation: pull requests run checks without credentials, and the real `terraform plan` runs only in the deploy workflow, because the role trusts one branch (FR-7).

Traceability: FR-7 (deviation note), FR-10.1.

### Step 16: Code summary (documentation)
- [x] Write `aidlc-docs/construction/reference-deployment/code/code-summary.md` with:
  - the list of files created and changed;
  - the pins resolved in step 1, with sources;
  - a map from requirements to files;
  - known limitations.

### Step 17: Static self-check (no build or run; that is Build and Test)
- [x] Grep every new and changed file for 12-digit numbers, `arn:aws:iam::<digits>`, `tfstate-<digits>` and IPv4 literals other than the documentation range and VPC CIDRs. Each must have no hits.
- [x] Do the `builder-security` sweep: check every `0.0.0.0`, ingress rule, `--host`/`listen` and `ports:` hit, and make sure each is accounted for (ID §8).
- [x] Check that every `uses:` line references a 40-character SHA.
- [x] Check that every workflow declares `permissions` explicitly.

Traceability: constraint 2, constraint 3, NFR-1, NFR-4, ID §8.

---

## Scope Estimate
- 17 steps.
- About 22 files created or changed:
  - `app/`: 3 files;
  - `infra/`: 11 files, including the 2 test files and the lock file;
  - `.github/workflows/`: 3 files;
  - `docs/`: 2 files;
  - `README.md`: 1 file;
  - `aidlc-docs/`: 1 summary.
- External lookups are read-only:
  - the GitHub API for the action SHAs;
  - the registry for the nginx digest and the Terraform version;
  - the Terraform registry, for the lock file.
- No AWS calls.
