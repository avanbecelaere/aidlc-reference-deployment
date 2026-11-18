# Infrastructure Design: reference-deployment

Sources:
- `requirements.md` (approved);
- `reference-deployment-infrastructure-design-plan.md`, with answers Q1 X→A (after clarification), Q2 A, Q3 A, Q4 A;
- `reference-deployment-infrastructure-design-clarification-questions.md` (answer A: plain HTTP).

Provider: AWS, one account, one region (`vars.AWS_REGION`). IaC: Terraform `>= 1.10`, `hashicorp/aws ~> 6.0`, one root module in `infra/`.

---

## 1. Component to Resource Mapping

| Logical component (requirement) | Terraform resource | File |
|---|---|---|
| VPC (FR-2.1) | `aws_vpc.main` | `network.tf` |
| AZ discovery (FR-2.2) | `data.aws_availability_zones.available` | `network.tf` |
| Public subnets x2 (FR-2.2) | `aws_subnet.public[0..1]` | `network.tf` |
| Internet gateway and routing (FR-2.3) | `aws_internet_gateway.main`, `aws_route_table.public`, `aws_route_table_association.public[0..1]` | `network.tf` |
| Security group (FR-2.4) | `aws_security_group.service`, `aws_vpc_security_group_ingress_rule.http_operator`, `aws_vpc_security_group_egress_rule.https_out` | `network.tf` |
| ECR repository (FR-3) | `aws_ecr_repository.app` | `ecr.tf` |
| Execution role (FR-5) | `aws_iam_role.task_execution`, `aws_iam_role_policy_attachment.task_execution` | `iam.tf` |
| Caller identity and partition (FR-5.2) | `data.aws_caller_identity.current`, `data.aws_partition.current` | `iam.tf` |
| Log group (FR-4.4) | `aws_cloudwatch_log_group.app` | `ecs.tf` |
| Cluster (FR-4.1) | `aws_ecs_cluster.main` | `ecs.tf` |
| Task definition (FR-4.2) | `aws_ecs_task_definition.app` | `ecs.tf` |
| Service (FR-4.3, Q3) | `aws_ecs_service.app` | `ecs.tf` |
| Versions and backend (FR-6.1, FR-6.2) | `terraform {}` with an empty `backend "s3" {}` | `versions.tf` |
| Provider and tags (FR-6.4) | `provider "aws"` with `default_tags` | `providers.tf` |
| Inputs (FR-6.5) | variables | `variables.tf` |
| Outputs (FR-6.6) | outputs | `outputs.tf` |

Not managed by this module (constraint 1): the state bucket, the OIDC provider, the deploy role and its policy, and the permissions boundary policy. They are referenced only. The boundary is looked up by name.

---

## 2. Network

| Item | Value | Rationale |
|---|---|---|
| VPC CIDR | `var.vpc_cidr`, default `10.0.0.0/16` | Requirements default |
| DNS | `enable_dns_support = true`, `enable_dns_hostnames = true` | Fargate resolves ECR and Logs endpoints through the VPC resolver |
| AZs | `slice(data.aws_availability_zones.available.names, 0, 2)`, filtered to `state = "available"` and `opt-in-status = opt-in-not-required` | Two AZs, never opt-in Local Zones |
| Subnets | `cidrsubnet(var.vpc_cidr, 8, i)` for i = 0, 1, giving `10.0.0.0/24` and `10.0.1.0/24` | One public subnet per AZ |
| `map_public_ip_on_launch` | `false` | The public IP is assigned by the ECS service (`assign_public_ip = true`), not by the subnet. That keeps the dependency explicit at the place that matters. |
| Route table | `0.0.0.0/0` to the IGW, associated with both subnets | No NAT gateway or endpoints (FR-2.5) |

### Security group `aidlc-demo-service`
| Direction | Protocol/port | Peer | Rationale |
|---|---|---|---|
| Ingress | TCP 8080 | `var.operator_cidr` (a single `/32`) | Q1 go-ahead: plain HTTP, unauthenticated, one source |
| Egress | TCP 443 | `0.0.0.0/0` | The task needs only HTTPS out, to the ECR API, S3 for layers, and CloudWatch Logs. DNS goes to the VPC resolver, which security groups do not filter. This is narrower than "all egress" at no cost. |

There are no other rules. The rules are separate `aws_vpc_security_group_*_rule` resources, not inline blocks, so a change produces a clean diff.

`operator_cidr` validation, which must hold or the plan fails:
- `can(cidrhost(var.operator_cidr, 0))`. It must be valid IPv4 CIDR syntax.
- `endswith(var.operator_cidr, "/32")`.
- `var.operator_cidr != "0.0.0.0/32"`. Together with the `/32` rule, this means `0.0.0.0/0` can never be accepted (NFR-3).

---

## 3. Registry

| Setting | Value | Source |
|---|---|---|
| Name | `aidlc-demo` | FR-6.4 |
| `image_tag_mutability` | `IMMUTABLE` | Q8 / FR-3.1 |
| `image_scanning_configuration.scan_on_push` | `true` (basic scanning) | Q4-A |
| `force_delete` | `true` | FR-3.2 |
| Encryption | `AES256` (the default) | No KMS key, which would add cost and a resource |
| Visibility | Private. There is no repository policy, so access is through IAM only. | builder-security: no public registries |

---

## 4. IAM

### Execution role `aidlc-demo-task-execution`
- **Trust**: the `ecs-tasks.amazonaws.com` service principal, with the condition `aws:SourceAccount = <caller account id>`. This guards against the confused-deputy problem.
- **Permissions**: the AWS managed `AmazonECSTaskExecutionRolePolicy`, which covers ECR auth and pull, and log stream creation and writes.
- **Boundary**: `arn:${partition}:iam::${account_id}:policy/${var.permissions_boundary_name}`, where `permissions_boundary_name` defaults to `aidlc-demo-task-boundary`. The boundary as recorded allows exactly the same six actions as the managed policy, so the effective permissions equal the managed policy.
- **No task role** (FR-5.1). The container calls no AWS APIs.

### What the hand-made deploy role must allow (checklist, not managed here)
Terraform and the workflows call these APIs. The prerequisites say to expect iteration, so this list lets the policy be checked before the first run, not mid-demo.

| Area | Actions |
|---|---|
| State | `s3:ListBucket` on the bucket; `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` on `aidlc-demo/*`, which includes the `.tflock` lockfile |
| Network | `ec2:Create/Delete/Describe/ModifyVpc*`, `*Subnet*`, `*InternetGateway*` (including `Attach`/`Detach`), `*RouteTable*`, `*Route`, `*SecurityGroup*`, `AuthorizeSecurityGroupIngress/Egress`, `RevokeSecurityGroupIngress/Egress`, `ec2:CreateTags`, `ec2:DescribeAvailabilityZones`, `ec2:DescribeNetworkInterfaces` |
| Registry | `ecr:CreateRepository`, `DeleteRepository`, `DescribeRepositories`, `PutImageScanningConfiguration`, `PutImageTagMutability`, `TagResource`, `ListTagsForResource`, `GetAuthorizationToken`, `BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage`, `DescribeImages`, `DescribeImageScanFindings`, `BatchDeleteImage` |
| Compute | `ecs:CreateCluster`, `DeleteCluster`, `DescribeClusters`, `RegisterTaskDefinition`, `DeregisterTaskDefinition`, `DescribeTaskDefinition`, `DeleteTaskDefinitions`, `ListTaskDefinitions`, `CreateService`, `UpdateService`, `DeleteService`, `DescribeServices`, `ListTasks`, `DescribeTasks`, `TagResource`, `ListTagsForResource` |
| Logs | `logs:CreateLogGroup`, `DeleteLogGroup`, `DescribeLogGroups`, `PutRetentionPolicy`, `TagResource`, `ListTagsForResource` |
| IAM | `TaskRolesWithinBoundary` and `PassOnlyTaskRolesToEcs` from the prerequisites, plus read actions on `aidlc-demo-task-*`: `iam:GetRole`, `ListRolePolicies`, `ListAttachedRolePolicies`, `ListInstanceProfilesForRole` |
| Service-linked role | `iam:CreateServiceLinkedRole` for `ecs.amazonaws.com`, needed only if `AWSServiceRoleForECS` does not already exist in the account |
| Teardown check | `tag:GetResources` |

**Gap, confirmed 2026-11-18** from the AWS Service Authorization Reference and the IAM policy simulator, against the real deploy role. This corrects an earlier version of this section, which also listed `iam:DeleteRole`; `DeleteRole` does carry `iam:PermissionsBoundary`. `iam:TagRole` and `iam:UntagRole` do **not** carry the key, so `TaskRolesWithinBoundary` denies them. `CreateRole` with tags also needs `iam:TagRole`, so the first apply would fail. The simulator also showed `ecs:DeleteTaskDefinitions` and `tag:GetResources` as denied. The fix is a change to the hand-made policy, recorded in `aidlc-docs/audit.md`.

---

## 5. Compute

### Cluster `aidlc-demo`
- `setting { name = "containerInsights", value = "disabled" }`, stated explicitly (FR-4.1).

### Log group `/aidlc-demo/app`
- `retention_in_days = 1` (Q13).

### Task definition, family `aidlc-demo`
| Setting | Value |
|---|---|
| `requires_compatibilities` | `["FARGATE"]` |
| `network_mode` | `awsvpc` |
| `cpu` / `memory` | `256` / `512` |
| `runtime_platform` | `operating_system_family = "LINUX"`, `cpu_architecture = "X86_64"` (Q9) |
| `execution_role_arn` | the execution role |
| `task_role_arn` | not set (FR-5.1) |
| Container `app` | image `${repository_url}:${var.image_tag}`; `portMappings` 8080/tcp; `essential = true`; `awslogs` driver with group `/aidlc-demo/app`, `awslogs-region` from the provider region, `awslogs-stream-prefix = "app"` |

### Service `aidlc-demo`
| Setting | Value | Source |
|---|---|---|
| `launch_type` | `FARGATE` (platform `LATEST`) | FR-4.3 |
| `desired_count` | `1` | FR-4.3 |
| `network_configuration` | both public subnets, the service security group, **`assign_public_ip = true`** | FR-4.3, load-bearing |
| `deployment_circuit_breaker` | `enable = true`, `rollback = true` | Q3-A |
| `deployment_minimum_healthy_percent` / `maximum_percent` | `100` / `200` (the defaults) | For a moment two tasks run, each with its own IP. The new IP is read after the service is stable. |
| `propagate_tags` / `enable_ecs_managed_tags` | `SERVICE` / `true` | Tasks carry the project tag |
| `wait_for_steady_state` | `false` | The workflow waits instead (§7), which gives better failure output |

---

## 6. Terraform Layout, Inputs and Outputs

```text
infra/
  versions.tf          required_version, required_providers, backend "s3" {}
  providers.tf         provider "aws" { default_tags { tags = { project = var.project } } }
  variables.tf         project, vpc_cidr, operator_cidr, image_tag, permissions_boundary_name
  network.tf           VPC, subnets, IGW, routes, security group and rules
  ecr.tf               repository
  iam.tf               execution role, attachment, identity and partition data
  ecs.tf               log group, cluster, task definition, service
  outputs.tf           cluster_name, service_name, ecr_repository_url, log_group_name
  .terraform.lock.hcl  committed (gitignore comment)
  backend.hcl.example  placeholders only
```

| Variable | Type | Default | Validation |
|---|---|---|---|
| `project` | string | `aidlc-demo` | `^[a-z][a-z0-9-]{2,20}$` |
| `vpc_cidr` | string | `10.0.0.0/16` | valid CIDR |
| `operator_cidr` | string | none | see §2 |
| `image_tag` | string | none | non-empty |
| `permissions_boundary_name` | string | `aidlc-demo-task-boundary` | non-empty |

The region is not a variable. The provider reads `AWS_REGION` from the environment, which is `vars.AWS_REGION` in CI and the operator's shell locally.

`ecr_repository_url` contains the account id. In CI it is masked (§7). Locally it prints to the operator's own terminal.

`backend.hcl.example`:
```hcl
bucket       = "<PROJECT>-tfstate-<ACCOUNT_ID>"
key          = "<PROJECT>/terraform.tfstate"
region       = "<REGION>"
encrypt      = true
use_lockfile = true
```

---

## 7. Workflows

All three workflows use:
- `permissions` at the workflow level;
- `actions/checkout` and `hashicorp/setup-terraform` pinned to full commit SHAs, which I will look up in Code Generation, with the version in a comment;
- `aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd` (v6.3.0, reusing the pin from `verify-oidc.yml`), only in deploy and destroy;
- an exact Terraform version;
- `terraform_wrapper: false`, for plain output and real exit codes.

There are no other third-party actions.

### 7.1 `pr-checks.yml`
- `on: pull_request`, with `permissions: contents: read` and no AWS credentials (FR-7).
- Steps:
  1. checkout;
  2. `git grep -nE '(^|[^0-9A-Za-z])[0-9]{12}([^0-9A-Za-z]|$)'` over tracked files, which must find nothing;
  3. setup-terraform;
  4. `terraform -chdir=infra fmt -check -recursive`;
  5. `init -backend=false`;
  6. `validate`;
  7. `docker build --platform linux/amd64 app/`.

  Step 2 is a guard for NFR-1: it fails if an account-id-shaped number appears.

### 7.2 `deploy.yml`
- `on: workflow_dispatch`, with `permissions: id-token: write, contents: read`.
- `concurrency: { group: aidlc-demo-infra, cancel-in-progress: false }`, shared with destroy.
- Job guard: `if: github.ref == 'refs/heads/main'`. The trust policy enforces this anyway; the guard fails it early with a clear message.
- Job environment:
  - `PROJECT=aidlc-demo`;
  - `AWS_REGION=${{ vars.AWS_REGION }}`;
  - `TF_IN_AUTOMATION=1`;
  - `TF_INPUT=0`;
  - `TF_VAR_operator_cidr=${{ secrets.OPERATOR_CIDR }}`;
  - `TF_VAR_image_tag=${{ github.sha }}`.

| # | Step | Detail |
|---|---|---|
| 1 | Checkout | |
| 2 | Assume role | `role-to-assume: vars.AWS_DEPLOY_ROLE_ARN`, `aws-region: vars.AWS_REGION`, `mask-aws-account-id: true` |
| 3 | Mask account id | `ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)`; `echo "::add-mask::$ACCOUNT_ID"`; export it to `$GITHUB_ENV`. This is in addition to the action's own masking (FR-8.3). |
| 4 | Write `backend.hcl` | bucket `${PROJECT}-tfstate-${ACCOUNT_ID}`, key `${PROJECT}/terraform.tfstate`, region, `encrypt`, `use_lockfile`. Written into the runner workspace only. |
| 5 | Set up and init Terraform | `terraform -chdir=infra init -backend-config=backend.hcl` |
| 6 | Make sure the repository exists | `terraform apply -target=aws_ecr_repository.app -auto-approve`. Does nothing once the repository exists (FR-8.6.1). |
| 7 | ECR login | `aws ecr get-login-password \| docker login --username AWS --password-stdin $REGISTRY` |
| 8 | Build and push | If `aws ecr describe-images --image-ids imageTag=$SHA` already finds the tag, skip; immutable tags make a re-run of the same commit otherwise fail. If not, run `docker build --platform linux/amd64 -t $REPO:$SHA app/` and `docker push`. |
| 9 | Scan summary (Q4-A) | `aws ecr wait image-scan-complete`, then print `findingSeverityCounts`. `continue-on-error: true`, so it never blocks the deploy. |
| 10 | Plan | `terraform plan -out=tfplan`. The plan prints in the log, with the operator CIDR and account id masked. |
| 11 | Apply | `terraform apply tfplan` |
| 12 | Wait for stable (Q3-A) | `aws ecs wait services-stable --cluster aidlc-demo --services aidlc-demo`. On failure, print `stoppedReason` for the most recent stopped tasks, then fail. |
| 13 | Find the public IP | `list-tasks` gives the task ARN, `describe-tasks` gives the ENI id, and `describe-network-interfaces` gives `Association.PublicIp`. Printed as `Service address: http://<ip>:8080/`. The task IP is not secret; it changes on every deployment. |
| 14 | Check that others are refused (Q2-A) | `code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://$IP:8080/ \|\| true)`. Passes only if `code == 000`, meaning no HTTP response. Any HTTP status fails the job: the runner's address is not the operator's, so a response means the ingress rule is wider than intended. |

The positive check, that the operator address gets the fixed response, is done by hand: `curl http://<ip>:8080/` from the operator's machine. CI cannot do it, because it has no operator address.

### 7.3 `destroy.yml`
- `on: workflow_dispatch` with the input `confirm`, which is required, of type string, with the description "Type aidlc-demo to destroy".
- Same permissions and concurrency group as deploy.
- Guard: `github.ref == 'refs/heads/main' && inputs.confirm == 'aidlc-demo'`.
- Environment: `TF_VAR_operator_cidr` comes from the secret, and `TF_VAR_image_tag=destroy`. Both are placeholders the variables require, and they don't affect what gets destroyed.

| # | Step | Detail |
|---|---|---|
| 1 to 5 | Same as deploy steps 1 to 5 | |
| 6 | Destroy | `terraform destroy -auto-approve` |
| 7 | Clean up task definitions | Delete the `INACTIVE` revisions of family `aidlc-demo` with `aws ecs delete-task-definitions`. Otherwise deregistered revisions stay listed under the project tag, which would defeat success criterion 5. |
| 8 | Check for an empty plan | `terraform plan -detailed-exitcode`. Exit code 0 is required; 2 fails the job (FR-9.3). |
| 9 | Tag query | `aws resourcegroupstaggingapi get-resources --tag-filters Key=project,Values=aidlc-demo`, then print the ARNs. It is expected to show nothing that Terraform created. The hand-made state bucket may appear and is listed for the operator to see. Hand-made removal follows `docs/prerequisites.md` Removal. |

---

## 8. Exposure and Security Review (NFR-10, builder-security)

| Item | Finding | Disposition |
|---|---|---|
| Ingress | TCP 8080 from one `/32`, enforced by validation. Plain HTTP, no auth. | **Accepted by explicit go-ahead.** Q1, clarified to A at 2026-11-18T15:37:29Z. Who can reach it: only the operator address; everyone else is dropped. What they reach: a constant body. |
| Egress | TCP 443 only | Narrower than the default |
| Refusal of other callers | Verified automatically on every deploy (§7.2 step 14) | builder-security: "verify denial, not success" |
| Task's public IP | Required for image pulls without NAT or endpoints | Vision §3 design decision. Only port 8080 is open to the `/32`. |
| Container listener | nginx binds `0.0.0.0:8080` inside the task | Acceptable: the security group is the boundary, as with a container publish (builder-security bind rule) |
| Execution role | Managed execution policy, inside the boundary, with source-account condition on trust. No task role. | Least privilege for this workload |
| Deploy role | Hand-made and not changed here. The confirmed `TagRole`/`UntagRole` condition gap is described in §4. | Operator action if it occurs |
| Base image | `nginxinc/nginx-unprivileged:<version>-alpine`, pinned by digest, runs as non-root (uid 101). Scanned on push, with a summary in the log. | Digest and version resolved in Code Generation |
| Registry | Private, IAM only, with immutable tags | builder-security: no public registries |
| Identifiers | Nothing account-specific in tracked files. The account id and operator CIDR are masked in logs. CI has a 12-digit grep guard. | NFR-1, NFR-2 |
| Not addressed | TLS, auth, WAF, secrets management, multi-account | Out of scope by vision §5 and §6. Presented as a teaching artifact. |

ARCC was queried for network exposure and for IAM on the execution role, and both queries returned no results. The `builder-security` policy is the governance applied.
