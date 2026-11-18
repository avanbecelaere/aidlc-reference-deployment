# Prerequisites

Created once, by hand, before any Terraform is applied. Not authored in
Terraform, and **not removed by `terraform destroy`**.

**Attendees need to bring nothing.** No backlog item, repository access,
credentials, environment, or preparation.

Copy `local-values.template.md` to `local-values.md` and fill it in as you go.
That file is gitignored.

> The security governance review normally required for IAM work has not been run
> on these policies. Review them before applying.

---

## You need

- [ ] An AWS account you can create and destroy resources in
- [ ] Credentials able to create IAM providers, IAM roles, and S3 buckets
- [ ] A GitHub repository with this code, and admin on it
- [ ] Terraform (1.10 or later, for S3 native state locking)
- [ ] Docker, or a CI runner that provides it
- [ ] A region and a project tag chosen

```bash
export AWS_REGION=<REGION>
export ACCOUNT_ID=<ACCOUNT_ID>
export PROJECT=<PROJECT_TAG>
export BUCKET="${PROJECT}-tfstate-${ACCOUNT_ID}"
export ROLE_NAME="${PROJECT}-github-deploy"
export GH_OWNER=<OWNER>
export GH_REPO=<REPO>
export OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
```

## Container architecture

Decide before the first build. The two halves must agree.

| Build on | Task definition runtime platform |
|---|---|
| CI (`ubuntu-latest`, x86_64) | `X86_64` |
| An arm64 workstation | `ARM64`, or build with `--platform linux/amd64` |

State it explicitly in the task definition. A default that matches your machine
but not your reader's is the failure everyone who copies you will hit.

- [ ] Choice recorded in `local-values.md`

## Pre-flight, read-only

```bash
aws sts get-caller-identity
aws ec2 describe-availability-zones \
  --query 'AvailabilityZones[?State==`available`].ZoneName'
aws ec2 describe-vpcs --query 'length(Vpcs)'   # default quota is 5 per region
aws iam list-open-id-connect-providers          # reuse one if present
```

## 1. State bucket

```bash
aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

aws s3api put-bucket-tagging --bucket "$BUCKET" \
  --tagging "TagSet=[{Key=project,Value=$PROJECT}]"
```

Omit `LocationConstraint` in `us-east-1`, where passing it fails. Versioning is
not optional: state records every resource attribute in plaintext, including
values marked sensitive.

Backend block for the root module:

```hcl
terraform {
  backend "s3" {
    bucket       = "<BUCKET>"
    key          = "<PROJECT_TAG>/terraform.tfstate"
    region       = "<REGION>"
    encrypt      = true
    use_lockfile = true
  }
}
```

- [ ] Bucket created, private, versioned, encrypted

## 2. OIDC identity provider

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --tags Key=project,Value="$PROJECT"
```

No thumbprint. It is optional in current CLI versions, and hardcoded ones from
older guides expire.

- [ ] Provider created or reused

## 3. Deploy role

**Do not copy a `sub` value from any example, including this one.** The claim has
two shapes:

```
repo:OWNER/REPO:ref:refs/heads/BRANCH                      older
repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/BRANCH     newer
```

A policy in the wrong shape fails with `AccessDenied`, "Not authorized to perform
sts:AssumeRoleWithWebIdentity", naming no condition. A trailing wildcard does not
help: the mismatch is early in the string, at `OWNER@` where the pattern expects
`OWNER/`.

Create the role, run the workflow once, read the rejected subject from CloudTrail,
then pin it:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 10 --query 'Events[].CloudTrailEvent' --output text
```

Read `userIdentity.userName`. Prefer this to printing claims in a workflow, whose
logs are public on a public repository.

```bash
cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "$OIDC_ARN" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": { "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": "<OBSERVED_SUB>"
    }}
  }]
}
EOF

aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document file:///tmp/trust-policy.json \
  --max-session-duration 3600 \
  --tags Key=project,Value="$PROJECT"

# After observing the real subject
aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
  --policy-document file:///tmp/trust-policy.json
```

Pinning the whole subject pins the branch and, in the newer shape, the numeric
ids, which are never reissued. Never write `repo:OWNER/*`.

- [ ] Observed subject recorded in `local-values.md`
- [ ] Pinned with `StringEquals`, no wildcard

## 4. Role permissions

Scope by service and name prefix. Expect to iterate: Terraform reports each
missing action as an `AccessDenied` naming the API.

Two statements are mandatory, whatever else you grant:

```json
{
  "Sid": "TaskRolesWithinBoundary",
  "Effect": "Allow",
  "Action": ["iam:CreateRole","iam:DeleteRole","iam:TagRole","iam:UntagRole",
             "iam:AttachRolePolicy","iam:DetachRolePolicy",
             "iam:PutRolePolicy","iam:DeleteRolePolicy"],
  "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/<PROJECT_TAG>-task-*",
  "Condition": { "StringEquals": { "iam:PermissionsBoundary": "<BOUNDARY_ARN>" } }
},
{
  "Sid": "PassOnlyTaskRolesToEcs",
  "Effect": "Allow",
  "Action": "iam:PassRole",
  "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/<PROJECT_TAG>-task-*",
  "Condition": { "StringEquals": { "iam:PassedToService": "ecs-tasks.amazonaws.com" } }
}
```

Without the boundary condition, a role that can create roles can create one more
privileged than itself. Without the `PassedToService` condition, an unconstrained
`PassRole` lets the holder become anything.

Never attach an administrator policy.

- [ ] Policy attached, and both conditions present

## 5. GitHub repository

```bash
gh variable set AWS_DEPLOY_ROLE_ARN \
  --body "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}" \
  --repo "${GH_OWNER}/${GH_REPO}"
gh variable set AWS_REGION --body "$AWS_REGION" --repo "${GH_OWNER}/${GH_REPO}"
```

A variable, not a secret. A role ARN is an identifier.

Every workflow assuming the role needs:

```yaml
permissions:
  id-token: write
  contents: read
```

Without `id-token: write` the runner injects no request variables and the failure
looks like a network problem.

- [ ] Variables set

## Verification

Run `.github/workflows/verify-oidc.yml`. It probes each policy statement and
**asserts the role cannot list IAM users**. That negative check is the only one
that distinguishes a scoped policy from an administrator policy.

- [ ] All steps pass

## Removal

Nothing here is created by Terraform. No `destroy` removes any of it.

```bash
aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn <POLICY_ARN>
aws iam delete-role --role-name "$ROLE_NAME"
aws iam delete-policy --policy-arn <POLICY_ARN>
aws iam delete-policy --policy-arn <BOUNDARY_ARN>
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN"

# Versioning retains objects after a plain delete, so clear all versions first
aws s3api delete-objects --bucket "$BUCKET" --delete "$(aws s3api list-object-versions \
  --bucket "$BUCKET" --output json \
  --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')"
aws s3api delete-objects --bucket "$BUCKET" --delete "$(aws s3api list-object-versions \
  --bucket "$BUCKET" --output json \
  --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}')"
aws s3api delete-bucket --bucket "$BUCKET"

gh variable delete AWS_DEPLOY_ROLE_ARN --repo "${GH_OWNER}/${GH_REPO}"
```

Delete the identity provider only if nothing else in the account uses it.

```bash
aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=project,Values=$PROJECT" \
  --query 'ResourceTagMappingList[].ResourceARN'
```

- [ ] Teardown run and verified empty
