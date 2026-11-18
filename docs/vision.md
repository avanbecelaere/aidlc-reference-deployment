# Vision: AI-DLC reference deployment

Status: draft for review
Date: 2026-11-17

This is the Inception input for an AI-DLC v1 run, executed in Claude Code. It is
written to be shareable with the engineering teams who will reproduce it, so it
carries no commercial or account context.

**It is deliberately small.** The whole thing has to go through AI-DLC in a single
working day, leaving time to build and rehearse. Scope discipline is a
requirement of this document, not a compromise in it.

---

## 1. Purpose

Demonstrate the AI-DLC flow end to end: a written intent becomes a specification,
then a design, then infrastructure and application code, with a human approving
each stage, deploying to a real AWS account through a CI workflow.

The artifact on display is **the process**. The application is trivial on purpose
so that nothing about it competes for attention with the workflow that produced
it.

## 2. Who this is for

Engineering teams early in their AWS adoption who keep source in GitHub, deploy
with GitHub Actions, and manage infrastructure with Terraform.

The audience's own infrastructure as code is an existing, customised Terraform
estate. What they want is to see **two things they can correlate**: infrastructure
as code they recognise, and an application component deployed on top of it. That
pairing, not a count of sample applications, is what makes the demonstration land.

## 3. The system

One containerised HTTP service on Amazon ECS, running on Fargate, returning a
fixed response.

- A container image built from a minimal Dockerfile in this repository.
- A private ECR repository holding it.
- An ECS cluster, task definition, and service running a single task.
- Terraform for all of it, in a single root module, with state in S3.
- A GitHub Actions workflow that plans on a pull request, and on an explicit
  trigger builds the image, pushes it, and applies.

ECS on Fargate is the workload. A containerised service is representative of how
an application actually reaches AWS, so the process stays visible against
infrastructure the audience already recognises, and it exercises the workflow
against something real rather than something toy.

### Design decisions

- **No load balancer.** The task runs with a public IP in the default VPC's public
  subnets. This is the single largest cost item and the slowest resource to create
  and destroy, and the demonstration does not need a stable hostname. The cost is
  that the address changes on each deployment, so it is read after deploying
  rather than known in advance.
- **No VPC build.** The account's default VPC is used as-is.
- **One Terraform root module**, not separate layers.

### Network exposure

The service listens on the public internet, so its ingress must be **restricted to
a single operator address**, not opened to the world. A fixed response in an
isolated account is low-value, but an unrestricted ingress rule is the wrong thing
to teach and the wrong thing to leave running. Only the presenter needs to reach
it; the audience watches a shared screen.

I was unable to run this repository's usual security governance check while
drafting, so treat the ingress rule, the task role, and the image's base layer as
needing a review pass before the deployment is shown to anyone.

### Established by hand, before anything is applied

Two things are created manually, outside this repository, and are **not** authored
in Terraform here:

1. The S3 bucket holding Terraform state. Terraform cannot create the bucket its
   own state lives in without a second state to track it, and that second state is
   exactly the complexity this scope avoids.
2. The trust relationship and role that let the GitHub Actions workflow obtain
   credentials in the account.

The second is deliberate beyond convenience. Federation between a source control
provider and a cloud account is normally established once, centrally, by whoever
owns the account, rather than by each repository that wants to deploy. A
repository able to create its own trust relationship is a repository able to grant
itself access.

Both must be **written down precisely enough to repeat**, including how they are
removed afterwards. See `docs/prerequisites.md`.

## 4. What success looks like

1. Every AI-DLC stage produced a written artifact that a human approved before the
   next stage began, and the approval is visible in `aidlc-docs/audit.md` rather
   than only in the conversation.
2. The service answers an HTTP request after a deployment that ran through GitHub
   Actions, not from a workstation.
3. A reader can follow the chain from this document to the running task without
   having been present.
4. A second engineer can clone the repository, supply their own AWS account and
   GitHub repository, follow `docs/prerequisites.md`, and reach a working
   deployment with no verbal instruction.
5. Teardown removes everything, verified by a plan reporting no changes and by
   finding nothing left under the project tag.

Criterion 4 is the one that usually fails in demonstrations, which is why it is
stated rather than assumed.

## 5. Scope boundaries

### Out of scope

- A second application workload. One service.
- A load balancer, and any stable public hostname or TLS certificate.
- Multiple environments or a promotion pipeline. One account, one environment.
- Separate Terraform layers.
- Autoscaling, monitoring, alerting, disaster recovery beyond service defaults.
- Authentication on the endpoint. See section 6.
- Any real business logic, data store, or integration.

### Why the system is this small

The scope is set by what one working day of AI-DLC can carry end to end, with time
left to build and rehearse. Anything larger buys no additional understanding of
the workflow and adds things that can fail while an audience watches.

Keeping the system genuinely simple also shortens the AI-DLC run. v1 adapts its
depth to the work and treats User Stories, Application Design and Units Generation
as conditional stages. A single-unit scope with no business logic should skip all
three, leaving Requirements Analysis, Workflow Planning, and one pass through the
construction stages. That is what makes a single day realistic.

## 6. What this is not

A teaching artifact, not a production starting point, and it must not be presented
as one. It does not address multi-account separation, secrets management, network
egress control, backup, or compliance posture. The endpoint is unauthenticated,
acceptable only because it returns a constant, is reachable from one address, and
lives in an isolated account for a matter of hours.

Anyone reproducing it should treat the security configuration as the minimum
needed to function and review it against their own standards before reusing the
pattern.

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Claude Code's own plan mode displaces AI-DLC's workflow | the process being demonstrated silently never runs | run in normal mode, never plan mode; verify activation by the presence of `aidlc-docs/aidlc-state.md`, never by what the agent reports. See `docs/running-aidlc-v1.md` |
| Auto-accept edits is enabled, so files are written with no human decision | the human-in-the-loop claim is false in the one place the audience can see it | keep permission prompts on for the whole run; they are the only mechanical gate present |
| Stage gates do not hold and the agent runs ahead into code generation | the central claim fails live and visibly | gates in v1 are prose, not enforcement; watch for a stage artifact followed by the next stage in the same turn, and read the audit log as you go |
| Residual files from an earlier attempt cause a resume or a brownfield misclassification | the run starts from the wrong state and surfaces later as something unrelated | start from a clean committed tree with no `aidlc-docs/` present |
| Image build or push fails during the session | the deployment half of the demonstration stalls on screen | have a known-good image already in the registry before the session, so the build is a demonstration rather than a dependency |
| Ingress left open to the internet | an unauthenticated public endpoint in an account that stays in use | restrict ingress to one operator address; never 0.0.0.0/0 |
| Resources left running afterwards | ongoing cost, and a Fargate task runs until stopped | tag everything with one project tag; verify teardown by plan and by tag query |
| The hand-made trust relationship outlives the demonstration | a standing access path in a live account | no `destroy` removes what Terraform did not create; remove it by hand as an explicit teardown step |
| The CI role carries more privilege than the deployment needs | a teaching artifact becomes a real risk | scope the trust to one repository and one branch or environment, never a wildcard; keep the role off blanket administrative policies |

## 8. Teardown

- `terraform destroy` on the single root module. Confirm the ECS service has
  scaled to zero tasks and the task has actually stopped, since a running task
  bills until it does.
- Delete the images in the ECR repository if the repository itself is not
  destroyed with the module.
- Remove the hand-created state bucket, and the trust relationship and role, by
  hand as explicit separate steps. Terraform did not create them, so no destroy
  will remove them, and they will otherwise outlive the demonstration in an
  account that stays in use. This is the step most likely to be skipped under time
  pressure.
- Verify with a plan reporting no resources, and by querying the account for the
  project tag.
- Record what was verified, so a later reader can tell teardown happened rather
  than assume it.
