# Setting up GitHub Actions to assume an AWS role, with no stored keys

A walkthrough of OpenID Connect federation between GitHub Actions and an AWS
account: what it is doing, how to set it up, and the two places it usually goes
wrong.

`docs/prerequisites.md` is the terse checklist for doing this. This document is
the explanation behind it.

---

## 1. What this replaces, and why it is worth the trouble

The old pattern is an IAM user with an access key pair stored as two GitHub
secrets. It works, and it has three problems that never go away: the key is
long-lived, it exists in two places at once, and nothing about it expires if
someone leaves or a laptop is lost.

With OIDC there is no stored key. Each workflow run asks GitHub for a short-lived
signed token describing itself, hands that token to AWS STS, and gets temporary
credentials back. Nothing persists between runs. There is no secret to rotate,
leak, or forget about.

## 2. How the trust actually works

Three parties and four steps.

```
  GitHub Actions job                AWS STS                  IAM
         |                             |                      |
  1. ask GitHub for a token            |                      |
     (needs id-token: write)           |                      |
         |                             |                      |
  2. AssumeRoleWithWebIdentity ------->|                      |
         |                             |  3. verify signature |
         |                             |     against the      |
         |                             |     identity provider|
         |                             |                      |
         |                             |  4. check the role's |
         |                             |     trust policy     |
         |<--- temporary credentials --|      conditions      |
```

The token is a JWT whose claims describe the run: which repository, which branch
or tag, which workflow, which event. AWS verifies the signature, then checks
those claims against conditions you write in the role's trust policy.

**The trust policy is the entire security boundary.** The identity provider only
establishes that GitHub signed the token. It says nothing about *which*
repository's token is acceptable. Without conditions, any repository on GitHub
that can reach your account's provider could assume your role.

Two claims matter most:

| Claim | Meaning | Typical condition |
|---|---|---|
| `aud` | audience the token was minted for | `StringEquals` on `sts.amazonaws.com` |
| `sub` | subject: who this run is | `StringEquals` on the exact observed value |

## 3. The three things you create

### a. An IAM OIDC identity provider

One per AWS account. If the account already has one for GitHub, reuse it rather
than creating a second.

```bash
aws iam list-open-id-connect-providers
```

If nothing comes back for `token.actions.githubusercontent.com`:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

**No thumbprint.** Older guides pass `--thumbprint-list` with a hardcoded
certificate fingerprint. AWS removed that requirement for GitHub as a provider,
and the parameter is now optional. Check your own CLI if you want to confirm it
rather than take this on faith:

```bash
aws iam create-open-id-connect-provider help | sed -n '/SYNOPSIS/,/OPTIONS/p'
```

A parameter shown in square brackets is optional. Copying a stale thumbprint from
a blog post gives you a provider that stops working when the certificate rotates,
and the failure looks like a signature problem rather than a configuration one.

The provider ARN is deterministic, so you can write it without looking it up:

```
arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com
```

### b. A role with a trust policy

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "<THE OBSERVED SUBJECT>"
      }
    }
  }]
}
```

Read section 4 before filling in the subject. It is the step that fails.

### c. Permissions on the workflow

```yaml
permissions:
  id-token: write    # allows the job to request the OIDC token
  contents: read
```

Without `id-token: write`, GitHub injects none of the request variables and the
job cannot obtain a token at all. The resulting failure does not mention
permissions: it looks like a network or credentials problem. This is the cheapest
mistake to make and one of the more confusing to read.

Then, in the job:

```yaml
- uses: aws-actions/configure-aws-credentials@<COMMIT_SHA>
  with:
    role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
    aws-region: ${{ vars.AWS_REGION }}
```

Pin the action to a **commit SHA**, not a tag. A tag can be repointed at new code
by anyone who can write to that repository; a commit cannot. Resolve the SHA for
whichever version you want:

```bash
gh api repos/aws-actions/configure-aws-credentials/releases/latest --jq .tag_name
gh api repos/aws-actions/configure-aws-credentials/git/ref/tags/<TAG> --jq .object.sha
```

If that returns an object of type `tag` rather than `commit`, dereference it:

```bash
gh api repos/aws-actions/configure-aws-credentials/git/tags/<SHA> --jq .object.sha
```

The role ARN belongs in a repository **variable**, not a secret. A role ARN is an
identifier, not a credential, and putting it in a secret only makes build logs
harder to read.

## 4. The subject claim, which is where this goes wrong

**Do not copy a `sub` value from an example, including from this document.**

The claim has two shapes. The older one, which nearly every tutorial shows:

```
repo:OWNER/REPO:ref:refs/heads/BRANCH
```

The newer one, which embeds the numeric owner and repository ids with `@`
separators. This was observed directly on a repository created in November 2026:

```
repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/BRANCH
```

A policy written in the old shape cannot match a token in the new one. That much
is unsurprising. What catches people is **why a wildcard does not rescue it**.

The instinct on failure is to loosen the condition to a prefix match:

```json
"StringLike": { "token.actions.githubusercontent.com:sub": "repo:OWNER/REPO:*" }
```

That still fails, because the mismatch is **early in the string**. The token says
`repo:OWNER@12345/...` where the pattern expects `repo:OWNER/`. The wildcard only
covers the tail, so it never gets a chance to help. It looks like insurance and
provides none, which sends people hunting for a cause in the audience, the
provider, or the region instead.

### What the failure looks like

```
AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

That message names no condition. It is identical whether the problem is the
subject, the audience, a missing identity provider, or a typo in the provider
ARN. The action may also retry it a dozen times with a growing backoff, which
buries the message in noise.

### Find the real value instead of guessing

CloudTrail records `AssumeRoleWithWebIdentity`, **including failed attempts**, and
the rejected subject is in the event:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 10 --query 'Events[].CloudTrailEvent' --output text
```

Read `userIdentity.userName`. That is the subject the token carried. Then pin it
with `StringEquals` and re-run. Events can lag a few minutes.

The alternative is printing the token's claims inside the workflow. It works, but
on a **public** repository the build log is readable by anyone, and the token
itself is a usable credential until it expires, so one careless `echo` of the
whole JWT is a real leak. CloudTrail avoids the question entirely.

### A benefit of the newer shape

Because the numeric ids are inside the subject, pinning the whole subject pins
them too. Ids are never reissued. So a repository created later with the same
name by someone else cannot match your policy, and renaming yours breaks the
policy loudly rather than silently transferring trust to whoever takes the name.

If your repository sends the older shape and you want that property, add the
`repository_id` and `repository_owner_id` claims as separate conditions. Confirm
they are present in the token first: a condition naming a claim the token does not
carry denies every request, and looks exactly like every other failure here.

## 5. How tightly to pin it

Pinning the full subject pins the branch as well, which is usually what you want.
It excludes tags, other branches, and pull requests, because each sends a
different subject.

On a **public** repository this matters more than it first appears. Anyone can
open a pull request against your repository, and a workflow triggered by that
pull request runs in your repository's context. GitHub restricts what tokens such
runs receive, but do not make that restriction your only defence. Either pin the
ref, or gate the deploy behind a GitHub environment with required reviewers and
pin the environment in the condition.

**Never** write `repo:OWNER/*` or anything broader. That grants every repository
belonging to that owner, present and future.

The consequence of pinning tightly is worth stating plainly: any workflow needing
this role must run on the pinned ref. A pull-request-triggered job will fail with
the same opaque `AccessDenied`. Add the extra subject deliberately rather than
loosening back to a wildcard.

## 6. Verifying it, including the half people skip

A positive test proves the role works:

```yaml
- run: aws sts get-caller-identity
```

That is not sufficient. It passes identically whether your role is scoped
correctly or carries administrator access. Add a **negative** assertion that
fails the build if the role can do something it should not:

```yaml
- name: Assert the role cannot do what it should not
  run: |
    set +e
    aws iam list-users --max-items 1 >/dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo "FAIL: the role can list IAM users. It is wider than intended."
      exit 1
    fi
    echo "correctly denied"
```

This repository's `.github/workflows/verify-oidc.yml` does both: one probe per
statement in the deploy policy, plus that negative check.

Checking from the AWS side, without running anything:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn <ROLE_ARN> \
  --action-names iam:CreateUser iam:AttachUserPolicy ec2:RunInstances \
  --query 'EvaluationResults[].{action:EvalActionName,decision:EvalDecision}' \
  --output table
```

All three should come back denied.

## 7. What the role is allowed to do

Separate from trust. The trust policy decides *who* may assume the role; its
permissions policy decides what they can then do. Two statements deserve
attention whatever else you grant.

If the role can create IAM roles, scope that by name prefix **and** require a
permissions boundary. A role that can create roles can otherwise create one more
privileged than itself:

```json
"Condition": { "StringEquals": { "iam:PermissionsBoundary": "<BOUNDARY_ARN>" } }
```

If the role can pass roles, scope `iam:PassRole` to specific roles and to the
service that will receive them. An unconstrained `PassRole` lets the holder adopt
the identity of anything:

```json
"Condition": { "StringEquals": { "iam:PassedToService": "ecs-tasks.amazonaws.com" } }
```

Never attach an administrator policy to a deployment role. It is the fastest route
to a working pipeline and it leaves something in the account that can do anything,
reachable from a source control system.

## 8. Common failures, and what each looks like

| Symptom | Likely cause |
|---|---|
| `AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity` | subject condition does not match. Read the real subject from CloudTrail |
| The same error, but the subject looks right | audience mismatch, or the `Federated` principal names a provider ARN that does not exist |
| Looks like a missing-credentials or network error | the job has no `id-token: write` |
| Worked, then stopped after a rename | subject pinned to the old repository name |
| Worked for a push, fails for a pull request | different subject. Expected if you pinned the ref |
| Signature or certificate errors | a hardcoded thumbprint that has since rotated |

## 9. Removing it

None of this is created by Terraform, so no `terraform destroy` removes any of
it. Each piece has to go by hand.

```bash
aws iam detach-role-policy --role-name <ROLE> --policy-arn <POLICY_ARN>
aws iam delete-role --role-name <ROLE>
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com
```

Delete the identity provider **only** if nothing else in the account uses it.

A federated trust relationship and a deployment role left behind are a standing
path from a source control system into your AWS account, long after anyone
remembers why they exist. Removing them is part of the work, not tidying up after
it.
