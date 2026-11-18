# Requirements Verification Questions

Input: `docs/vision.md`, plus the four constraints in the initial request (see `aidlc-docs/audit.md`).

Answer each question by putting a letter after its `[Answer]:` tag. If no option fits, choose X and describe what you want on the same line. Each question starts with why it matters and which option I recommend. The recommendations are only suggestions, and nothing is decided until you answer.

---

## Part 1: CI workflow

## Question 1
**Plan on pull request.** The vision says the workflow "plans on a pull request". `docs/prerequisites.md` pins the deploy role's trust policy to one branch with `StringEquals` on `sub` (`...:ref:refs/heads/BRANCH`). A `pull_request` run presents a different `sub` (`...:pull_request`), so it cannot assume the role. Pull requests from forks get no OIDC token at all. `verify-oidc.yml` also states the intent to keep the role away from pull requests in this public repository. A real `terraform plan` needs AWS credentials. What should the pull-request job do?

Recommendation: A. It needs no change to hand-made resources, but the wording in the vision's §3 is then only partly met. The real plan runs, and is visible, in the manual-trigger job just before apply.

A) Run checks without credentials on pull requests (`terraform fmt -check`, `terraform init -backend=false`, `terraform validate`, and a `docker build` with no push). Run the real `terraform plan` only in the manual-trigger job.

B) Run a real `terraform plan` on pull requests. You would widen the trust policy on the hand-made role by hand to also accept the `pull_request` subject. I would only update the text of `docs/prerequisites.md`. Fork pull requests still could not plan.

C) Remove the pull-request job entirely.

X) Other (please describe after [Answer]: tag below)

[Answer]: a

## Question 2
**Manual trigger.** The vision says that "on an explicit trigger" the workflow builds, pushes and applies. The role trusts one branch only. A GitHub Environment with required reviewers would change the `sub` claim to `...:environment:NAME`, which the existing trust policy would reject. What should the trigger be?

Recommendation: A.

A) `workflow_dispatch`, run from the default branch only, in one job: plan, build and push, then apply. There is no GitHub Environment.

B) `workflow_dispatch` with a GitHub Environment and a required reviewer. You would update the hand-made trust policy by hand to the environment subject.

X) Other (please describe after [Answer]: tag below)

[Answer]: a

## Question 3
**Backend configuration in CI.** The `backend.hcl` file is gitignored, so the CI runner has to produce one. Per `docs/prerequisites.md`, the bucket name is `<PROJECT>-tfstate-<ACCOUNT_ID>`. `verify-oidc.yml` already derives the account id from `sts get-caller-identity`. How should CI get the backend values?

Recommendation: A. It adds no new variable and nothing account-specific to tracked files.

A) After assuming the role, derive the bucket from the caller identity plus the project tag. Write `backend.hcl` on the runner, with key `<PROJECT>/terraform.tfstate` and region from `vars.AWS_REGION`. A tracked `backend.hcl.example` with placeholders documents the format for local use.

B) Add a new repository variable `TF_STATE_BUCKET` and write `backend.hcl` from it.

X) Other (please describe after [Answer]: tag below)

[Answer]: a

## Question 4
**Account id in public Actions logs.** Your constraint covers tracked files. On a public repository, Actions logs are also public. `terraform plan` output and the `docker push` output include the ECR registry host and IAM and ECS ARNs, and all of these contain the account id. Should the workflow hide it?

Recommendation: A. It is one line, and it matches the intent of the constraint.

A) Yes. Immediately after assuming the role, register the account id as a log mask (`::add-mask::`) so it is redacted from every later step's output.

B) No. The constraint applies to tracked files only, so accept the account id in logs.

X) Other (please describe after [Answer]: tag below)

[Answer]: a

---

## Part 2: Network exposure

## Question 5
**Where the operator address comes from.** The security group admits HTTP from a single operator address, and the vision says never `0.0.0.0/0`. The address cannot be in a tracked file. It will also show up in plan output in public logs unless it is masked. Where should it come from?

Recommendation: A. GitHub masks secret values in logs, which covers plan output.

A) A GitHub Actions **secret** `OPERATOR_CIDR`, for example `203.0.113.10/32`. It is passed to Terraform as `TF_VAR_operator_cidr`. Terraform validates that it is a single IPv4 `/32`.

B) A repository **variable** `OPERATOR_CIDR`. It is not masked, so the address appears in public logs.

C) A `workflow_dispatch` input typed at each run. It appears in the run's public event payload and logs.

X) Other (please describe after [Answer]: tag below)

[Answer]: a

---

## Part 3: Container and first deployment

## Question 6
**What serves the fixed response.** The vision flags the image's base layer for review. Which server should the container use?

Recommendation: A. You write no application code, the base is widely reviewed, and it runs as non-root.

A) `nginxinc/nginx-unprivileged` (Alpine variant), pinned by digest. It serves one static file, runs as a non-root user, and listens on **port 8080**. The security group admits 8080 from the operator address.

B) Official `nginx` (Alpine), pinned by digest. It runs as root and listens on **port 80**.

C) A tiny Go program compiled into a `scratch` or distroless image. It listens on port 8080 and adds a language toolchain to the build.

X) Other (please describe after [Answer]: tag below)

[Answer]: a

## Question 7
**First-deployment ordering.** Terraform creates the ECR repository, and the ECS service needs an image in it before the task can start. In a fresh clone nothing exists yet, and success criterion 4 says a second engineer must get there without verbal instructions. How should the manual-trigger job order the work?

Recommendation: A. The same job works on the first run and every run after. To pre-seed a known-good image (vision §7), you just run it once before the session.

A) Apply only the ECR repository with `terraform apply -target`, which does nothing once it exists. Then build and push the image. Then run a full plan and apply with the new image tag.

B) Split into two documented steps: a one-off bootstrap that creates ECR and pushes an image, and a separate deploy job.

C) Use a single full apply. The ECS service retries pulling until a later step pushes the image and forces a new deployment.

X) Other (please describe after [Answer]: tag below)

[Answer]: a

## Question 8
**Image tag.**

Recommendation: A.

A) Tag each image with the git commit SHA, and make ECR tags immutable. The task definition references that SHA, so the running task traces back to a commit (success criterion 3).

B) Use a mutable `latest` tag.

X) Other (please describe after [Answer]: tag below)

[Answer]: a

## Question 9
**CPU architecture.** `docs/prerequisites.md` says to decide this before the first build.

Recommendation: A.

A) `X86_64`. The image is built in CI on `ubuntu-latest`, and the runtime platform is stated explicitly in the task definition.

B) `ARM64`, built in CI with emulation or on an arm64 runner.

X) Other (please describe after [Answer]: tag below)

[Answer]: a

---

## Part 4: IAM

## Question 10
**Task roles.** The vision says "the task role" needs a review pass. A fixed response makes no AWS API calls, so it needs only a **task execution role** (to pull from ECR and write logs), not a task role. Which roles should be created?

Recommendation: A.

A) Only the execution role, named `<PROJECT>-task-execution`, with AWS's managed `AmazonECSTaskExecutionRolePolicy` attached. No task role.

B) Both an execution role and an empty task role, named `<PROJECT>-task-app`.

X) Other (please describe after [Answer]: tag below)

[Answer]: a

## Question 11
**Permissions boundary.** The deploy policy in `docs/prerequisites.md` §4 only lets the deploy role create `<PROJECT>-task-*` roles when they carry a specific permissions boundary. Its ARN contains the account id, and the prerequisites don't give the boundary a name. How should Terraform reference it?

Recommendation: A. Fill in the actual boundary policy name after the letter, for example `A, aidlc-demo-task-boundary`.

A) Use a Terraform variable `permissions_boundary_name`, with a tracked default set to the name you give. Terraform builds the ARN from the caller identity at plan time, so nothing account-specific is tracked.

B) Add a new repository variable `TASK_ROLE_BOUNDARY_ARN` holding the full ARN.

X) Other (please describe after [Answer]: tag below)

[Answer]: a

---

## Part 5: Naming, logs and teardown

## Question 12
**Project tag and name prefix.** This value is used in every resource name, the `project` tag, the state bucket name and the IAM name prefix. `verify-oidc.yml` already assumes `aidlc-demo`.

Recommendation: A.

A) `aidlc-demo`

X) Other (please describe after [Answer]: tag below)

[Answer]: a

## Question 13
**Container logs.** The vision expects the task to reach CloudWatch Logs, while monitoring and alerting are out of scope.

Recommendation: A.

A) Create one CloudWatch log group with 1-day retention and use the `awslogs` driver. No Container Insights, alarms or dashboards.

B) No logging configuration at all.

X) Other (please describe after [Answer]: tag below)

[Answer]: a

## Question 14
**Where teardown runs.** Vision §8 requires `terraform destroy`, with the result verified by a plan that shows no changes and by a query on the project tag. It doesn't say where destroy runs.

Recommendation: A. It uses the same scoped role as deploy and needs no administrator credentials on a workstation.

A) A separate `workflow_dispatch` destroy workflow. It only runs if you type the project tag as a confirmation input. It then runs a final plan that must show no changes.

B) Run `terraform destroy` locally from a workstation, as documented steps.

C) Add a `deploy`/`destroy` choice input to the same workflow as the deploy job.

X) Other (please describe after [Answer]: tag below)

[Answer]: a

---

## Part 6: AI-DLC extensions

## Question 15: Security Extensions
Should security extension rules be enforced for this project?

Note: whatever you answer here, the vision's specific review items still get an explicit review pass in Construction: the ingress rule, the IAM roles and the base image. The full baseline may pull in controls the vision lists as out of scope. If it does, I will stop and tell you rather than add them.

A) Yes — enforce all SECURITY rules as blocking constraints (recommended for production-grade applications)

B) No — skip all SECURITY rules (suitable for PoCs, prototypes, and experimental projects)

X) Other (please describe after [Answer]: tag below)

[Answer]: b

## Question 16: Resiliency Extensions
Should the resiliency baseline be applied to this project?

**What this extension is.** Enabling it applies a set of **directional, design-time best practices** for building resilient systems, derived from the **AWS Well-Architected Framework (Reliability Pillar)** and resilience-review guidance. It steers requirements, design, and code toward fault tolerance, high availability, observability, and recoverability — covering 15 practice areas across business goals, change management, observability, high availability, disaster recovery, and continuous improvement.

**What this extension is NOT.** Enabling it does **not** make your workload production-ready, nor does it certify or guarantee any availability, RTO, or RPO target. It is a **starting point** that scaffolds good resiliency decisions early — it is not a substitute for a formal **AWS Well-Architected Review** of the built system.

Treat the output as a well-grounded **first draft of your resiliency posture** to build on and validate — not a finished, production-certified result.

Note: the vision rules out autoscaling, monitoring, alerting and disaster recovery beyond service defaults.

A) Yes — apply the resiliency baseline as directional best practices and design-time guidance (recommended for business-critical workloads, as an informed starting point that you can validate and harden before go-live)

B) No — skip the resiliency baseline (suitable for PoCs, prototypes, and experimental projects where rapid iteration matters more than reliability)

X) Other (please describe after [Answer]: tag below)

[Answer]: b

## Question 17: Property-Based Testing Extension
Should property-based testing (PBT) rules be enforced for this project?

Note: this project has no application code with logic in it.

A) Yes — enforce all PBT rules as blocking constraints (recommended for projects with business logic, data transformations, serialization, or stateful components)

B) Partial — enforce PBT rules only for pure functions and serialization round-trips (suitable for projects with limited algorithmic complexity)

C) No — skip all PBT rules (suitable for simple CRUD applications, UI-only projects, or thin integration layers with no significant business logic)

X) Other (please describe after [Answer]: tag below)

[Answer]: c

---

## Defaults I will use unless you object (no answer needed)

- VPC `10.0.0.0/16`, with two public `/24` subnets in the first two available AZs, looked up through a data source.
- ECS service: `desired_count = 1`, launch type Fargate, `assign_public_ip = true` (load-bearing, see vision §3), 0.25 vCPU and 512 MiB.
- ECR repository with `force_delete = true`, so `terraform destroy` removes it along with its images (vision §8).
- Terraform `>= 1.10` and AWS provider `~> 6.0`. `.terraform.lock.hcl` is committed. The provider's `default_tags` puts `project = <PROJECT>` on every resource.
- The response body is a fixed plain-text line. It doesn't change between deployments.
