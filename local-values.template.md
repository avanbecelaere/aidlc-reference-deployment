# Local values

Copy this file to `local-values.md` and fill it in. That filename is gitignored,
so your values stay out of the repository.

```bash
cp local-values.template.md local-values.md
```

Account ids are not secrets, but there is no reason to publish which account a
deployment ran in. Keeping them here is also what lets `docs/prerequisites.md`
stay a template anyone can follow.

The **Value** column below holds example values, so you can see what each entry
looks like. Replace every one with your own.
- Names that start with `aidlc-demo` are the defaults this repository's code
  expects. If you choose a different project tag, change them all to match.
- `<ACCOUNT_ID>` stays a placeholder even in the examples. The pull-request check
  rejects any 12-digit number committed to the repository.
- `example-org` and `203.0.113.10` are illustrative values. `203.0.113.0/24` is an
  address range reserved for documentation.

## Order of work

The step-by-step commands live in the docs, not here. This file only records the
values you choose and observe along the way.

1. `docs/prerequisites.md`: create the resources Terraform does not manage, in order:
   - §1: the state bucket;
   - §2: the OIDC provider;
   - §3: the deploy role, with its observed `sub` pinned;
   - §4: the boundary policy and the deploy policy;
   - §5: the repository variables and the `OPERATOR_CIDR` secret.

   Then run **Verification** (`verify-oidc.yml`). Fill in the tables below as you go.
2. `docs/deploy.md`: run the **Deploy** workflow, read the service address from
   its log, and `curl` it from your operator address.
3. `docs/deploy.md` → Tear down: run the **Destroy** workflow and let it finish.
   Then `docs/prerequisites.md` → **Removal** deletes everything from step 1.

---

## Account

| Thing | Value |
|---|---|
| Account id | `<ACCOUNT_ID>` (your 12-digit id) |
| Region | `us-west-2` |
| Project tag | `aidlc-demo` |
| Profile or auth method | `aidlc-demo-admin` (an SSO profile in `~/.aws/config`) |

Authentication command for this account:

```
aws sso login --profile aidlc-demo-admin
export AWS_PROFILE=aidlc-demo-admin
aws sts get-caller-identity
```

## GitHub

| Thing | Value |
|---|---|
| Owner | `example-org` |
| Repository | `aidlc-reference-deployment` |
| Default branch | `main` |
| Visibility | `public` |
| Repository variable `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::<ACCOUNT_ID>:role/aidlc-demo-github-deploy` |
| Repository variable `AWS_REGION` | `us-west-2` |
| Repository secret `OPERATOR_CIDR` | `203.0.113.10/32` (your public IP, as a single `/32`) |

## Named resources

| Thing | Value |
|---|---|
| State bucket | `aidlc-demo-tfstate-<ACCOUNT_ID>` |
| State key | `aidlc-demo/terraform.tfstate` |
| OIDC provider ARN | `arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com` |
| Deploy role name | `aidlc-demo-github-deploy` |
| Deploy role ARN | `arn:aws:iam::<ACCOUNT_ID>:role/aidlc-demo-github-deploy` |
| Deploy policy ARN | `arn:aws:iam::<ACCOUNT_ID>:policy/aidlc-demo-deploy` |
| Deploy policy default version | `v3` (record each version you create and why) |
| Permissions boundary ARN | `arn:aws:iam::<ACCOUNT_ID>:policy/aidlc-demo-task-boundary` |
| Task execution role (created by Terraform) | `aidlc-demo-task-execution` |

Backend block:

```hcl
terraform {
  backend "s3" {
    bucket       = "aidlc-demo-tfstate-<ACCOUNT_ID>"
    key          = "aidlc-demo/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
```

The code keeps that block empty and reads the values from `infra/backend.hcl`,
which is gitignored. To run Terraform locally, copy `infra/backend.hcl.example` to
`infra/backend.hcl` and fill in the same values.

## The observed OIDC subject

Do not fill this in from an example. Create the role, run the workflow once, and
read the rejected or accepted subject from CloudTrail.

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 10 --query 'Events[].CloudTrailEvent' --output text
```

Read `userIdentity.userName`. The examples below show only the **shape** of the two
possible values. Your owner, repository and numeric ids will differ.

| Thing | Value |
|---|---|
| Observed subject | `repo:example-org@<OWNER_ID>/aidlc-reference-deployment@<REPO_ID>:ref:refs/heads/main` |
| Shape (older or newer) | `newer`. The older shape is `repo:example-org/aidlc-reference-deployment:ref:refs/heads/main` |
| Date observed | `2026-11-18` |

## Container architecture

| Thing | Value |
|---|---|
| Workstation architecture | `arm64` |
| Build location (CI or local) | `CI` (`ubuntu-latest`, x86_64) |
| Task definition runtime platform | `X86_64` (set in `infra/ecs.tf`) |

## Progress

- [ ] Pre-flight checks run
- [ ] State bucket created, private, versioned, encrypted
- [ ] OIDC identity provider created or reused
- [ ] Deploy role created
- [ ] Subject observed and pinned with `StringEquals`
- [ ] Permissions boundary created
- [ ] Deploy policy attached, both IAM conditions present
- [ ] Deploy policy checked against the API list in `docs/prerequisites.md` §4
- [ ] Repository variables set
- [ ] `OPERATOR_CIDR` secret set
- [ ] `verify-oidc` workflow passes, including the negative assertion
- [ ] First `terraform apply` succeeded
- [ ] Teardown run and verified empty on:

## Notes

Anything account-specific worth remembering: quota limits hit, actions added to
the policy during iteration, deviations from the documented steps.

Example: *2026-11-18. Policy v2 added `iam:TagRole`/`iam:UntagRole` limited to
the `project` tag key, `ecs:DeleteTaskDefinitions`, and `tag:GetResources`. v3
added `ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer`, which `docker push`
needs.*
