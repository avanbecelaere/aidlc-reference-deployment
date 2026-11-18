# Deploying and tearing down

This runbook covers getting from a clone that has its prerequisites in place to a
running service, and back to nothing. It assumes `docs/prerequisites.md` is
complete: the state bucket, the OIDC provider, the deploy role and its policy, the
permissions boundary, the repository variables, and the `OPERATOR_CIDR` secret.

Everything runs in GitHub Actions. No AWS credentials are needed on a workstation.

---

## What gets deployed

```text
app/      Dockerfile and index.html. nginx-unprivileged returns one fixed line on 8080.
infra/    One Terraform root module: VPC, 2 public subnets, IGW, security group,
          ECR repository, ECS cluster, task definition, service, log group,
          task execution role.
```

- The task runs in a public subnet with a public IP.
- There is no load balancer, so **the address changes on every deployment**. You
  read it from the deploy log.
- Only the address in `OPERATOR_CIDR` can reach it, on port 8080, over plain HTTP.
  There is no authentication. That is acceptable only because the service returns
  a constant and runs for a few hours in an isolated account (see
  `docs/vision.md`, section 6).

## Workflows

| Workflow | Trigger | Credentials | What it does |
|---|---|---|---|
| `pr-checks.yml` | every pull request | none | Account-id grep, `terraform fmt`/`validate`/`test`, `docker build` |
| `deploy.yml` | manual, from `main` | deploy role via OIDC | Creates ECR if needed, builds and pushes the image, `plan`, `apply`, waits for the service, prints its address, checks that the runner is refused |
| `destroy.yml` | manual, from `main`, typed confirmation | deploy role via OIDC | `destroy`, deletes inactive task definitions, requires a plan with no changes, lists anything still tagged |

Pull requests do **not** run `terraform plan`. The deploy role trusts the `main`
branch only, so a pull-request run cannot assume it, and pull requests from forks
get no OIDC token at all. The real plan runs in the deploy workflow immediately
before apply, and you can read it in that log.

---

## Before the first deploy

1. Check the deploy role's policy against the API list in
   `aidlc-docs/construction/reference-deployment/infrastructure-design/infrastructure-design.md`,
   section 4. In particular, check the `iam:TagRole` / `iam:UntagRole` gap noted
   in `docs/prerequisites.md`, section 4.
2. Make sure the `OPERATOR_CIDR` secret is your **current** public address as a
   `/32`:

   ```bash
   curl -s https://checkip.amazonaws.com
   gh secret set OPERATOR_CIDR --body "<that-address>/32"
   ```

3. Optionally, pre-seed a known-good image before an audience is watching. Run
   Deploy once beforehand. Later runs reuse what exists.

## Deploy

```bash
gh workflow run deploy.yml --ref main
gh run watch
```

You can also start it from GitHub: Actions, then Deploy, then Run workflow, on
`main`.

The job takes about 3 to 5 minutes. At the end, the log and the run summary show:

```text
Service address: http://<task-public-ip>:8080/
correctly unreachable from the runner (no response within 10s)
```

From the operator machine:

```bash
curl http://<task-public-ip>:8080/
# Hello from aidlc-demo: deployed through GitHub Actions by an AI-DLC workflow.
```

The second log line is the automatic negative check. The runner's address is not
yours, so the runner must get no response. If it got any HTTP status, the job
fails: the security group admits more than the operator.

### What the image tag tells you

Each image is tagged with the commit SHA it was built from, and ECR tags are
immutable. The running task definition therefore names exactly one commit. You can
follow the chain from `docs/vision.md` to the running task:

```text
vision -> aidlc-docs -> commit -> image tag -> task definition
```

## Tear down

```bash
gh workflow run destroy.yml --ref main -f confirm=aidlc-demo
gh run watch
```

The job:

1. runs `terraform destroy`;
2. deletes inactive ECS task definitions, which Terraform can only deregister;
3. runs `terraform plan -detailed-exitcode`, and **fails unless it reports no
   changes**;
4. prints every resource still tagged `project=aidlc-demo`. Expect nothing that
   Terraform created. The hand-made state bucket may appear.

Then remove the hand-made pieces as separate, explicit steps, following
`docs/prerequisites.md`, Removal: the deploy role and its policies, the boundary
policy, the OIDC provider (only if nothing else uses it), the state bucket, and
the repository variables and secret. Destroy needs the role and the bucket, so it
must run **before** you remove them.

Record what you verified, the destroy run URL and the final tag query, in
`aidlc-docs/audit.md`. A later reader can then tell that teardown happened rather
than assume it.

---

## Running Terraform locally (optional)

This is not needed for the deployment. It is useful for inspecting state.

```bash
cp infra/backend.hcl.example infra/backend.hcl     # gitignored; fill in
export AWS_REGION=<REGION>                         # plus credentials for the account
export TF_VAR_operator_cidr="<your-ip>/32"
export TF_VAR_image_tag="<deployed-commit-sha>"
terraform -chdir=infra init -backend-config=backend.hcl
terraform -chdir=infra plan
```

These need no AWS access:

```bash
terraform -chdir=infra init -backend=false
terraform -chdir=infra validate
terraform -chdir=infra test          # mocked provider
docker build --platform linux/amd64 app/
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The run is not on `main`, or the trust policy's `sub` does not match | Run from `main`. See `docs/prerequisites.md`, section 3, on observing the real `sub` |
| `AccessDenied` naming an API during `apply` | The hand-made deploy policy lacks that action | Add it to the policy, scoped by name prefix, and run Deploy again |
| `AccessDenied` on `iam:TagRole` | The boundary condition is on an action that does not carry the key | See `docs/prerequisites.md`, section 4 |
| Deploy fails at "Wait for the service", with `CannotPullContainerError` | No route to ECR from the task | `assign_public_ip` must be `true` and the subnet must route to the IGW. Both are asserted by `terraform test` |
| "Service is stable on a different image (rolled back?)" | The new task failed to start, and the circuit breaker restored the previous one | Read the "Why the tasks stopped" step and the `/aidlc-demo/app` log group |
| `curl` from your machine times out | Your public address changed, or the secret is wrong | Update `OPERATOR_CIDR`, then run Deploy again |
| Validation error on `operator_cidr` | The secret is not a single `/32` | Set it to `<ip>/32` |
| Re-running Deploy on the same commit skips the build | Tags are immutable, so the existing image is reused | Expected |
