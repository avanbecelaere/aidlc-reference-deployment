# Requirements: AI-DLC reference deployment

## Intent Analysis

| Item | Value |
|---|---|
| User request | Build the system in `docs/vision.md` through AI-DLC, under four added constraints (see `aidlc-docs/audit.md`, Initial User Request) |
| Request type | New Project |
| Clarity | Clear once the 17 verification questions were answered |
| Scope | Single component: one Terraform root module, one container image, two GitHub Actions workflows |
| Complexity | Simple |
| Requirements depth | Standard |

Source of answers: `requirement-verification-questions.md`. All 17 questions are answered. No contradictions were found (see §8).

---

## 1. Functional Requirements

### FR-1 HTTP service
- **FR-1.1** One container serves a fixed plain-text HTTP response. The body is constant and does not change between deployments.
- **FR-1.2** The server is `nginxinc/nginx-unprivileged` (Alpine variant), pinned by image digest. It runs as non-root and listens on **TCP 8080**. (Q6)
- **FR-1.3** The image is built from a minimal `Dockerfile` in this repository. Its only additions to the base are a static response file and, if needed, a minimal server config.

### FR-2 Network (Terraform)
- **FR-2.1** One VPC, `10.0.0.0/16`.
- **FR-2.2** Two public subnets (`/24`), one in each of the first two available AZs, found through a data source.
- **FR-2.3** An internet gateway, plus a route table with `0.0.0.0/0 -> IGW`, associated with both subnets.
- **FR-2.4** One security group:
  - Ingress allows TCP 8080 from `var.operator_cidr` only.
  - Egress is unrestricted, so the task can reach ECR and CloudWatch Logs through the IGW.
- **FR-2.5** No NAT gateway, no VPC endpoints and no load balancer.

### FR-3 Registry (Terraform)
- **FR-3.1** One private ECR repository with **immutable** tags. (Q8)
- **FR-3.2** `force_delete = true`, so `terraform destroy` removes it along with its images (vision §8).

### FR-4 Compute (Terraform)
- **FR-4.1** One ECS cluster. Container Insights is not enabled.
- **FR-4.2** One Fargate task definition:
  - `runtime_platform` is stated explicitly: `LINUX` / `X86_64`. (Q9)
  - 0.25 vCPU and 512 MiB.
  - `network_mode = awsvpc`.
  - The image reference is `<ecr_repo_url>:<var.image_tag>`.
- **FR-4.3** One ECS service:
  - `desired_count = 1` on Fargate, placed in both public subnets.
  - **`assign_public_ip = true`**. This is load-bearing: without it the image pull fails (vision §3).
- **FR-4.4** One CloudWatch log group with 1-day retention, used by the `awslogs` log driver. No alarms, dashboards or Container Insights. (Q13)

### FR-5 IAM (Terraform)
- **FR-5.1** Exactly one role is created, the **task execution role**, named `aidlc-demo-task-execution`. It has the AWS managed `AmazonECSTaskExecutionRolePolicy` attached. No task role is created. (Q10)
- **FR-5.2** The role carries the permissions boundary `arn:aws:iam::<caller account>:policy/<var.permissions_boundary_name>`. Terraform builds the ARN from `aws_caller_identity`. (Q11)
- **FR-5.3** The default for `permissions_boundary_name` is **`aidlc-demo-task-boundary`**.
  - This name is taken from the `${PROJECT}-task-boundary` naming in the operator's local prerequisite notes, because the Q11 answer gave no name. **Confirm at review.**
  - The boundary as recorded allows the ECR pull and log-write actions the managed policy needs, so the two are compatible.

### FR-6 Terraform layout and state
- **FR-6.1** One root module. Terraform `>= 1.10`, AWS provider `~> 6.0`, with `.terraform.lock.hcl` committed.
- **FR-6.2** The `backend "s3" {}` block is empty in code. Values come from a gitignored `backend.hcl`. A tracked `backend.hcl.example` holds placeholders only. (Constraint 2)
- **FR-6.3** The backend uses bucket `aidlc-demo-tfstate-<ACCOUNT_ID>`, key `aidlc-demo/terraform.tfstate`, `encrypt = true` and `use_lockfile = true`.
- **FR-6.4** The provider's `default_tags` sets `project = aidlc-demo` on every resource. Resource names are prefixed `aidlc-demo`. (Q12)
- **FR-6.5** Inputs:
  - `operator_cidr` has no default. Validation requires a single IPv4 `/32`, and rejects `0.0.0.0/0`.
  - `image_tag` has no default.
  - `permissions_boundary_name` defaults to the name in FR-5.3.
  - `project` defaults to `aidlc-demo`.
  - The region comes from `AWS_REGION` in the environment.
- **FR-6.6** Output: the ECS cluster and service names, so the operator can look up the task's public IP after deploying. A helper command for that lookup is documented.

### FR-7 Pull-request workflow (no AWS credentials) (Q1-A)
- **FR-7.1** Triggered by `pull_request`. It runs `terraform fmt -check`, `terraform init -backend=false`, `terraform validate` and `docker build` with no push.
- **FR-7.2** It does not assume the role. `permissions: contents: read` only.
- **Accepted deviation.** Vision §3 says "plans on a pull request". A real plan runs only in the deploy workflow, because the existing trust policy pins the role to one branch. Record this in the vision or README so that a later reader isn't misled.

### FR-8 Deploy workflow (Q2-A, Q3-A, Q4-A, Q5-A, Q7-A, Q8-A)
- **FR-8.1** Trigger and runner:
  - Triggered by `workflow_dispatch`. A guard refuses to run off the default branch (`main`).
  - No GitHub Environment.
  - `permissions: id-token: write, contents: read`.
- **FR-8.2** Credentials:
  - The role is assumed through `aws-actions/configure-aws-credentials`, pinned to a commit SHA, using `vars.AWS_DEPLOY_ROLE_ARN` and `vars.AWS_REGION`.
  - Every third-party action is pinned to a commit SHA. (Constraint 3)
- **FR-8.3** Immediately after the role is assumed, the account id is registered with `::add-mask::`.
- **FR-8.4** `backend.hcl` is generated on the runner from the caller identity and the project tag, then `terraform init -backend-config=backend.hcl` runs.
- **FR-8.5** The operator address comes from the secret `secrets.OPERATOR_CIDR` as `TF_VAR_operator_cidr`.
- **FR-8.6** The steps run in this order:
  1. `terraform apply -target=<ecr repository>`. Once the repository exists, this changes nothing.
  2. Log in to ECR, then build the image tagged with `${{ github.sha }}` and push it.
  3. `terraform plan -out` with `image_tag = github.sha`. The plan is shown in the log.
  4. `terraform apply` of that saved plan.
- **FR-8.7** After the apply, the workflow waits for the service to become stable. It then prints the task's public IP, which is not a secret. The log line is documented as the place to read the address.

### FR-9 Destroy workflow (Q14-A)
- **FR-9.1** Triggered by `workflow_dispatch` with a required input, `confirm`. It proceeds only if `confirm == aidlc-demo`.
- **FR-9.2** It uses the same credential, masking and backend steps as FR-8.
- **FR-9.3** It runs `terraform destroy`, then a `terraform plan -destroy -detailed-exitcode` that must report no changes (corrected 2026-11-18), then a tag query for `project=aidlc-demo` resources.
  - The tag query will still list the hand-made state bucket, OIDC provider and role.
  - Those are removed by hand, per `docs/prerequisites.md` Removal.

### FR-10 Documentation
- **FR-10.1** The README or a short `docs/deploy.md` gives the operator's sequence: set the `OPERATOR_CIDR` secret, run deploy, read the IP, `curl`, run destroy, then do the manual removal steps. It must be enough to meet success criterion 4.
- **FR-10.2** `docs/prerequisites.md` adds the `OPERATOR_CIDR` secret and names the boundary policy, with placeholders only.
- **FR-10.3** The `.gitignore` gains no language-specific entries, because the stack has no build artifacts.

---

## 2. Non-Functional Requirements

| ID | Requirement | Source |
|---|---|---|
| NFR-1 | No account id, bucket name, role ARN or operator IP in any tracked file | Constraint 2, Q5 |
| NFR-2 | Account id and operator IP are masked in Actions logs | Q4, Q5 |
| NFR-3 | Ingress is never `0.0.0.0/0`. Enforced by variable validation. | Vision §3, §7 |
| NFR-4 | Third-party actions and the base image are pinned (commit SHA, image digest) | Constraint 3, Q6 |
| NFR-5 | Container runs as non-root | Q6 |
| NFR-6 | Everything created is tagged `project = aidlc-demo` | Vision §7, §8 |
| NFR-7 | Clean teardown leaves no Terraform-managed resources, verified by plan and tag query | Vision §4.5, §8 |
| NFR-8 | Reproducible from a clone plus `docs/prerequisites.md` with no verbal instruction | Vision §4.4 |
| NFR-9 | Running cost is near zero: one 0.25 vCPU Fargate task, with no ALB, NAT gateway or endpoints | Vision §3 |
| NFR-10 | Explicit review pass in Construction of the ingress rule, the IAM role and the base image, even though the Security extension is off | Vision §3, Q15 note |

---

## 3. Constraints

1. The state bucket, OIDC provider and deploy role already exist. No Terraform is written for them.
2. Partial backend configuration, with a gitignored `backend.hcl`.
3. Workflows read `vars.AWS_DEPLOY_ROLE_ARN` and `vars.AWS_REGION`, with `id-token: write` and `contents: read`. Actions are SHA-pinned.
4. Scope stays inside vision §5. Anything excluded that turns out to be needed triggers a stop, not an addition.
5. Delivery is today.

## 4. Out of Scope (from vision §5, unchanged)
- A second workload.
- A load balancer, hostname or TLS.
- More than one environment.
- Terraform layers.
- Autoscaling, monitoring, alerting or DR.
- Endpoint authentication.
- Business logic, data stores or integrations.
- A task role.
- Container Insights.

## 5. Extension Configuration

| Extension | Enabled | Answer |
|---|---|---|
| Security Baseline | No | Q15-B (NFR-10 still applies) |
| Resiliency Baseline | No | Q16-B |
| Property-Based Testing | No | Q17-C |

## 6. Success Criteria Traceability

| Vision §4 | Met by |
|---|---|
| 1. Every stage approved and recorded in audit.md | AI-DLC process |
| 2. Responds after a deployment through GitHub Actions | FR-8, FR-1 |
| 3. Chain from vision to running task | aidlc-docs, plus the git-SHA image tag (FR-8.6) |
| 4. A second engineer reproduces it | FR-10, NFR-8 |
| 5. Teardown verified | FR-9, NFR-7 |

## 7. Known Risks Carried Forward
- The deploy role's permissions were scoped iteratively, by hand. The first apply may hit an `AccessDenied` for an action this design needs. That is fixed in the hand-made policy, not here.
- The task's public IP changes on every deployment (accepted, vision §3).

## 8. Answer Validation
- There are no contradictions:
  - Q1-A and Q2-A agree on one trusted branch.
  - Q5-A and Q4-A together keep the IP and the account id out of logs.
  - Q6-A sets port 8080, which FR-2.4 then uses.
- One ambiguity: Q11 was answered A without a boundary name. It was resolved to `aidlc-demo-task-boundary` from the operator's local notes (FR-5.3), and is flagged for confirmation.
