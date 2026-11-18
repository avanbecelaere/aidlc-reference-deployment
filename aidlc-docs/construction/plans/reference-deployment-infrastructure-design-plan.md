# Infrastructure Design Plan: reference-deployment

Inputs:
- `aidlc-docs/inception/requirements/requirements.md` (approved);
- `aidlc-docs/inception/plans/execution-plan.md` (approved).

There are no Functional Design or NFR Design artifacts, because both stages were skipped by the approved plan. The logical components are taken straight from the requirements: FR-1 to FR-9 and NFR-1 to NFR-10.

Security governance checked:
- ARCC was queried twice, on network exposure and on IAM for the ECS execution role. It returned no results.
- The `builder-security` exposure policy is applied, because this unit delivers a network listener.

---

## Plan Steps

- [x] 1. Map each logical component in FR-1 to FR-9 to concrete AWS resources and Terraform files
- [x] 2. Network design: the CIDRs, how AZs are picked, routing and security-group rules
- [x] 3. Compute design: the task definition, service and deployment settings
- [x] 4. Registry design: the repository settings, tagging and scanning
- [x] 5. IAM design: the execution role, the boundary wiring, and how it relates to the hand-made deploy policy
- [x] 6. Terraform layout: the file split, variables, outputs, versions and backend
- [x] 7. Workflow design: the jobs, steps, action pins, masking, concurrency, and the guard on deploying off-branch
- [x] 8. Exposure review under NFR-10 and `builder-security`: the ingress rule, the IAM role and the base image
- [x] 9. Teardown and verification design
- [x] 10. Write `infrastructure-design.md` and `deployment-architecture.md`

---

## Question Category Evaluation

| Category | Status | Justification |
|---|---|---|
| Deployment Environment | Settled | One AWS account and region (`vars.AWS_REGION`), with a single environment (FR-6, vision §5) |
| Compute Infrastructure | Questions 3 and 4 | Fargate, 0.25 vCPU and 512 MiB, one task, X86_64, all settled. Deployment behaviour and image scanning are still open. |
| Storage Infrastructure | N/A | No data store (vision §5). Terraform state is in the hand-made bucket (constraint 1). |
| Messaging Infrastructure | N/A | No asynchronous processing or integrations (vision §5) |
| Networking Infrastructure | Questions 1 and 2 | The topology is settled (FR-2). The exposure needs your explicit go-ahead, and I propose a denial check. |
| Monitoring Infrastructure | Settled | One log group with 1-day retention. Alarms, dashboards and Insights are out of scope (Q13). |
| Shared Infrastructure | Settled | The state bucket, OIDC provider and deploy role are referenced only, never managed (constraint 1) |

---

## Question 1
**Explicit go-ahead for the public exposure.** Under the `builder-security` policy, a listener reachable from beyond its own network needs an explicit risk decision from you. A warning note in the design does not count. This is what the approved design delivers:

- **Who can reach what.** Anyone sending from the single `/32` in `OPERATOR_CIDR` can make **unauthenticated, plain-HTTP** requests to port 8080 on the task's public IP. Everyone else on the internet is dropped by the security group. Nothing else on the task is reachable.
- **What it returns.** A constant body, with no data behind it.
- **What is not there.** No TLS and no authentication, both by design (vision §5, §6). The only boundary is the security group's single source address.

The private alternative is to keep the security group with **no ingress at all** and reach the container over ECS Exec / SSM port forwarding. That needs a task role with `ssmmessages:*`, `enable_execute_command`, and the Session Manager plugin on the presenter's machine. It adds the task role the requirements excluded (FR-5.1), so it goes beyond the approved scope.

Recommendation: A. This is exactly the shape the vision asks for. The source address is narrow, and Question 2 adds an automatic check that the rule really does refuse other addresses.

A) Go ahead with the exposure as described: TCP 8080 from the single `OPERATOR_CIDR` `/32`, plain HTTP and unauthenticated

B) Do not expose it. Use the SSM port-forwarding alternative, accepting the scope change, which would require amending the requirements.

X) Other (please describe after [Answer]: tag below)

[Answer]: x, use /32 operator cidr, but use https

## Question 2
**Automatic check that other addresses are refused.** The policy says to prove that unintended callers are refused, not just that the intended one succeeds. The GitHub-hosted runner has an address that is not the operator's, so it can serve as the "anyone else" probe.

Recommendation: A.

A) After the service is stable, the deploy workflow runs `curl --max-time 10` from the runner against the task's public IP. The job **fails** if any HTTP response comes back. A timeout, the expected result, passes. You still check the positive path by hand with `curl` from the operator address.

B) No automatic check. Both checks are done by hand.

X) Other (please describe after [Answer]: tag below)

[Answer]: a  (changed from b at user request, 2026-11-18T15:35:38Z)

## Question 3
**Deployment behaviour on a bad deploy.** With ECS service defaults, a task that cannot pull its image or start keeps retrying indefinitely, and Terraform reports success anyway. This is the single most common first-deploy failure (vision §3, the missing public IP), and on screen it would look like a hang.

Recommendation: A. It is a deployment-safety setting, not monitoring or DR, and it costs nothing.

A) Turn on the ECS deployment circuit breaker with rollback. The workflow then waits with `aws ecs wait services-stable`, so a failed deploy fails the job within minutes, with the stopped-task reason printed.

B) Leave the service defaults. The workflow does not wait for the service to stabilise.

X) Other (please describe after [Answer]: tag below)

[Answer]: a

## Question 4
**Image scanning.** The vision asks for a review of the image's base layer. ECR basic scan-on-push is free and needs no extra resources.

Recommendation: A. Gating on findings would make the live demo depend on an upstream CVE feed.

A) Turn on `scan_on_push`. The deploy workflow prints a summary of findings by severity, and it does not gate on them.

B) Turn on `scan_on_push` and fail the deploy on any CRITICAL finding.

C) No scanning.

X) Other (please describe after [Answer]: tag below)

[Answer]: a  (changed from c at user request, 2026-11-18T15:35:38Z)

---

## Defaults I will use unless you object (no answer needed)

- **Layout**:
  - `infra/` holds `versions.tf`, `providers.tf`, `variables.tf`, `network.tf`, `ecr.tf`, `iam.tf`, `ecs.tf`, `outputs.tf`, the committed `.terraform.lock.hcl`, and `backend.hcl.example`.
  - `app/` holds the `Dockerfile` and `index.html`.
- **AZs**: the first two zones from `aws_availability_zones` with `state = "available"`, filtered to `opt-in-not-required`.
- **ECS**: `propagate_tags = "SERVICE"` and `enable_ecs_managed_tags = true`, so running tasks carry the project tag too.
- **Workflow actions**: as few as possible, each pinned to a full commit SHA with the version in a comment:
  - `actions/checkout`;
  - `hashicorp/setup-terraform`, with the Terraform version pinned exactly;
  - `aws-actions/configure-aws-credentials`, at the SHA already in `verify-oidc.yml`.

  ECR login and `docker build`/`push` use the AWS CLI and Docker directly, with no extra actions.
- **Concurrency**: deploy and destroy share one `concurrency` group and never cancel each other. State locking is a second layer of protection.
- **Destroy inputs**: the destroy and final-plan steps pass `OPERATOR_CIDR` from the secret, plus a placeholder `image_tag`. Both are required variables, and neither affects what gets destroyed.
- **Container hardening**: no read-only root filesystem. Fargate does not support `tmpfs`, and nginx needs a writable `/tmp`. Getting round that would mean adding a volume, which is not worth it for a constant response.
