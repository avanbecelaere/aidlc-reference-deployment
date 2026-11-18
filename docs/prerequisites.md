# Prerequisites

Status: **partly filled. Two values outstanding (AWS account id, GitHub
repository). Policies drafted but not reviewed.**
Date: 2026-11-17

Everything here is done **once, by hand, by whoever owns the AWS account**, before
any Terraform in this repository is applied. It is deliberately not authored in
Terraform. See `docs/vision.md` section 3 for why.

---

## Nothing is required from the audience

**If you are attending the demonstration, you need to bring nothing.** No backlog
item, no repository access, no credentials, no environment, and no preparation.
The deployment runs entirely in an AWS-owned account.

---

## Governance note, read before filling this in

The steps below create a federated trust relationship and an IAM role. The usual
security governance check for credential and IAM work **was not run** while
drafting this skeleton, because the tooling for it was unavailable in the
authoring session.

Treat every policy document below as a draft requiring review before it is
applied. The constraints called out are necessary, not sufficient.

---

## Still needed before any of this can be completed

Two things are unknown and only you can supply them. Everything else below is
either filled in or proposed.

1. **Which AWS account.** There are no credentials on the default profile
   (`aws sts get-caller-identity` returns `NoCredentials`), and `~/.aws/config`
   holds nineteen profiles with no obvious name for this one. The account id is
   needed for the state bucket name, the identity provider ARN and the role ARN.
2. **The GitHub repository.** This repo has no remote configured yet, so the
   owner and repository name are unknown. Both appear in the trust policy's
   `sub` condition, which cannot be written without them.

Values marked **proposed** below are my suggestion, not a decision. Change them
freely; they only need to be consistent with each other.

`<ACCOUNT_ID>` appears as a placeholder throughout, so this document stays a
template a reader can follow with their own account. If you are the operator, keep
your filled-in values in a local, untracked file rather than editing them in here.

---

## What the operator needs

- [ ] An AWS account they own and can safely create and destroy resources in.
      Account id: `TODO`
- [ ] Credentials for that account with permission to create IAM identity
      providers, IAM roles, and S3 buckets
- [ ] A GitHub repository holding this code, and admin on it: `<OWNER>/<REPO>`
- [x] Terraform installed locally. Version in use: **1.16.3** (linux_arm64)
- [ ] A region chosen and recorded: **proposed `us-west-2`**
- [ ] A single project tag chosen and recorded, used on every resource so teardown
      can be verified by tag query: **proposed `project = aidlc-demo`**
- [x] A container build tool. Docker 25.0.18 is present and its daemon is
      reachable. See the architecture note below, which matters more than the
      version does.

---

## Container architecture, decide before the first build

This workstation is `aarch64`, and its Docker is ARM too. **ECS Fargate defaults
its runtime platform to X86_64.** A locally built image therefore runs on an
architecture the task definition does not expect, and the task fails to start
with an exec format error, which reads like a corrupt image rather than an
architecture mismatch.

Pick one and write it down, because the two halves have to agree:

| Option | Build | Task definition |
|---|---|---|
| **Build in CI (recommended)** | GitHub Actions `ubuntu-latest` runners are x86_64, so the image is amd64 with no extra work | runtime platform `X86_64` |
| Build locally | `docker build --platform linux/amd64`, which runs under emulation and is slow | runtime platform `X86_64` |
| Go ARM throughout | needs an ARM runner or `buildx` with QEMU in CI | runtime platform `ARM64` |

- [ ] Option chosen: **proposed build in CI, task definition X86_64**
- [ ] The task definition states its runtime platform **explicitly**, rather than
      relying on the default

Stating the platform explicitly is the point, not a formality. A default that
happens to differ from the machine you build on is exactly the kind of thing that
works for the person who set it up and fails for everyone who copies it. The
audience will copy it.

This is also an argument for building in CI rather than locally, independent of
the demonstration: it is the only option where the architecture is right without
anyone having to remember a flag.

---

## Step 1: Terraform state bucket

Created by hand because Terraform cannot hold the state of the bucket its own
state lives in without a second state to track it.

- [ ] Create a private S3 bucket. Name: **proposed
      `aidlc-demo-tfstate-<ACCOUNT_ID>`** (S3 bucket names are globally unique, so
      the account id suffix avoids a collision with someone else's)
- [ ] Block all public access
- [ ] Enable versioning, so a corrupted state can be rolled back
- [ ] Enable default encryption
- [ ] Apply the project tag
- [ ] Record the backend configuration used by the root module:

```hcl
# Terraform 1.16.3 is in use, confirmed locally. Native S3 state locking landed
# in 1.10, so use_lockfile works and there is NO separate DynamoDB lock table to
# create. Older guidance that tells you to make one does not apply here.
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

---

## Step 2: GitHub OIDC identity provider

One per account. If the account already has one for
`token.actions.githubusercontent.com`, reuse it rather than creating a second.
Check first, read-only:

```bash
aws iam list-open-id-connect-providers
```

- [ ] Create an IAM OIDC identity provider
- [ ] Provider URL: `https://token.actions.githubusercontent.com`
- [ ] Audience: `sts.amazonaws.com`

A thumbprint is no longer required for GitHub as an identity provider, following
an AWS change; older tutorials still include a hardcoded one and those values go
stale. See the [AWS and GitHub OIDC notes](https://github.com/hassaku63/aws-github-oidc-no-use-thumbprint-test).

- [ ] Record the provider ARN. It is deterministic once you know the account id:
      `arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com`

---

## Step 3: The deployment role and its trust policy

**This is the security boundary of the whole setup.** AWS's own guidance is that
if the `sub` condition is not narrowed to your organisation or repository, then
workflows outside your control can assume the role. Pin it to one repository and,
where possible, one branch or environment. Content paraphrased from
[GitHub Actions to AWS OIDC federation guidance](https://nhimg.org/how-to-federate-github-actions-to-aws).

- [ ] Create a role. Name: **proposed `aidlc-demo-github-deploy`**
- [ ] Apply the project tag
- [ ] Trust policy, filled in from this skeleton:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<OWNER>/<REPO>:*"
        }
      }
    }
  ]
}
```

### The `sub` claim trap, which matters for a new repository

The `sub` claim has historically looked like
`repo:OWNER/REPO:ref:refs/heads/BRANCH`. Recent reports say that for
**repositories created since roughly July 2026 the claim also carries numeric
owner and repository IDs**, which breaks a condition written in the older shape.
See [this write-up](https://dev.to/sascha-ms/github-actions-oidc-aws-deploys-without-access-keys-3cm3)
and confirm against GitHub's current documentation before trusting either format.

The failure mode is an `AssumeRoleWithWebIdentity` denial that does not say which
condition rejected the token, which is a poor thing to debug on a deadline.

Deliberate staging, rather than guessing the format:

1. Start with `StringLike` on `repo:OWNER/REPO:*` as above. **The repository is
   still pinned**, which is the boundary AWS warns about; only the portion after
   the repository is left open.
2. Run the workflow once and observe the actual `sub` value the token carried.
3. Tighten to `StringEquals` on that exact observed value, including the branch or
   environment.

- [ ] Step 1 applied
- [ ] Actual `sub` value observed and recorded here: `TODO`
- [ ] Tightened to the exact value

Do not stop after step 1. A `*` after the repository still permits any branch,
any tag, and any pull request in that repository to assume the role. **On a public
repository this matters more**, because a pull request opened from a fork runs in
the context of your repository, so anyone can cause that workflow to run. Pin the
ref, or gate the apply behind a GitHub environment and pin the environment
instead.

**Never** write `repo:OWNER/*` or anything broader. That grants every repository
in the organisation.

### Consider conditioning on the numeric ids too

If the token carries `repository_id` and `repository_owner_id` claims, adding them
alongside `sub` makes the policy survive a repository rename, and stops anyone who
later claims the same repository name from matching it. Both ids are readable from
the GitHub API for your own repository.

Confirm the claims are actually present in the token before relying on them. A
condition naming a claim the token does not carry denies every request, and looks
identical to every other trust policy failure.

---

## Step 4: What the role is allowed to do

- [ ] Attach a permissions policy scoped to what this deployment actually creates
- [ ] Record the policy or its ARN: `TODO`

Constraints:

- **No blanket administrative policy.** It is the fastest route to a working demo
  and leaves a role in a live account that can do anything.
- Terraform here creates container registry, ECS, networking and IAM resources, so
  the policy is necessarily broad. Broad is not the same as unlimited. Write down
  which services it covers and why.
- The role needs read and write on the state bucket and its state key, and nothing
  else in S3.
- Granting the role the ability to modify IAM broadly lets it escalate its own
  privileges. If IAM actions are needed, scope them by resource path or
  permissions boundary rather than granting them outright.

---

## Step 5: GitHub repository configuration

- [ ] The workflow requests the token. Without this the job gets no OIDC token at
      all and the failure looks like a credentials problem:

```yaml
permissions:
  id-token: write
  contents: read
```

- [ ] Record the role ARN where the workflow can read it, as a repository variable
      rather than a secret, since a role ARN is not sensitive: `TODO`
- [ ] Decide whether apply is gated behind a GitHub environment with required
      reviewers. If so, the trust policy condition should name that environment.
      Decision: `TODO`

---

## Verification

Before the demonstration, confirm each of these by running it, not by inspection:

- [ ] A workflow run obtains credentials and `aws sts get-caller-identity` returns
      the expected role
- [ ] `terraform init` reaches the S3 backend
- [ ] `terraform plan` runs in CI on a pull request
- [ ] An apply completes and the service answers an HTTP request
- [ ] The `sub` condition has been tightened past step 1 and a run still succeeds

---

## Removal

None of this is created by Terraform, so **no `terraform destroy` will remove any
of it.** Each item needs deleting by hand, and this is the step most likely to be
skipped once the demonstration is over.

- [ ] Delete the IAM role
- [ ] Delete the OIDC identity provider, **only if** nothing else in the account
      relies on it
- [ ] Empty and delete the state bucket, including old object versions, which
      versioning keeps after a plain delete
- [ ] Remove the repository variable
- [ ] Confirm by tag query that nothing carrying the project tag remains
- [ ] Record here what was verified and when: `TODO`

A federated trust relationship and a deployment role left behind in an account
that stays in use are a standing access path, long after anyone remembers why
they exist.
