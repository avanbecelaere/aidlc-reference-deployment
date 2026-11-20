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

> New to this, or debugging a failure? `docs/github-oidc-setup.md` explains how
> the trust works, why a wildcard on the subject does not rescue a mismatch, and
> what each failure message actually means.

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

These are the two policies the deployment worked with. They were found by iterating against the
real code on 2026-11-18. Both use the variables exported at the top of this page.

Never attach an administrator policy.

### 4a. Permissions boundary

This boundary caps every role the deploy role creates. Terraform attaches it to
the one role it makes, `${PROJECT}-task-execution`, by looking it up by name. The
name comes from `permissions_boundary_name` in `infra/variables.tf`, whose default
is `aidlc-demo-task-boundary`. The boundary allows exactly what AWS's managed
`AmazonECSTaskExecutionRolePolicy` needs: pulling from ECR and writing logs.

```bash
cat > /tmp/boundary.json <<'EOF2'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
EOF2

aws iam create-policy --policy-name "${PROJECT}-task-boundary" \
  --policy-document file:///tmp/boundary.json \
  --description "Permissions boundary for roles created by the deploy role" \
  --tags Key=project,Value="$PROJECT"
export BOUNDARY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${PROJECT}-task-boundary"
```

### 4b. Deploy policy

The deploy policy is scoped by service and by name prefix. The heredoc below is
unquoted, so the shell fills in `${BUCKET}`, `${ACCOUNT_ID}`, `${AWS_REGION}`
and `${PROJECT}`.

```bash
cat > /tmp/deploy-policy.json <<EOF2
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformState",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::${BUCKET}/${PROJECT}/*"
    },
    {
      "Sid": "TerraformStateList",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::${BUCKET}"
    },
    {
      "Sid": "ReadOnlyDiscovery",
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "ecs:Describe*",
        "ecs:List*",
        "ecr:Describe*",
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetRepositoryPolicy",
        "ecr:ListTagsForResource",
        "logs:Describe*",
        "logs:ListTagsForResource",
        "iam:GetRole",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EcrManage",
      "Effect": "Allow",
      "Action": [
        "ecr:CreateRepository",
        "ecr:DeleteRepository",
        "ecr:TagResource",
        "ecr:UntagResource",
        "ecr:PutLifecyclePolicy",
        "ecr:PutImageTagMutability",
        "ecr:SetRepositoryPolicy",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:BatchDeleteImage",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/${PROJECT}*"
    },
    {
      "Sid": "EcsManage",
      "Effect": "Allow",
      "Action": [
        "ecs:CreateCluster",
        "ecs:DeleteCluster",
        "ecs:CreateService",
        "ecs:UpdateService",
        "ecs:DeleteService",
        "ecs:TagResource",
        "ecs:UntagResource",
        "ecs:RegisterTaskDefinition",
        "ecs:DeregisterTaskDefinition"
      ],
      "Resource": "*"
    },
    {
      "Sid": "NetworkingBuild",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVpc",
        "ec2:DeleteVpc",
        "ec2:ModifyVpcAttribute",
        "ec2:CreateSubnet",
        "ec2:DeleteSubnet",
        "ec2:ModifySubnetAttribute",
        "ec2:CreateInternetGateway",
        "ec2:DeleteInternetGateway",
        "ec2:AttachInternetGateway",
        "ec2:DetachInternetGateway",
        "ec2:CreateRouteTable",
        "ec2:DeleteRouteTable",
        "ec2:CreateRoute",
        "ec2:DeleteRoute",
        "ec2:AssociateRouteTable",
        "ec2:DisassociateRouteTable",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:CreateTags",
        "ec2:DeleteTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LogGroups",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:DeleteLogGroup",
        "logs:PutRetentionPolicy",
        "logs:TagResource",
        "logs:UntagResource"
      ],
      "Resource": "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:/${PROJECT}*"
    },
    {
      "Sid": "TaskRolesWithinBoundary",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/${PROJECT}-task-*",
      "Condition": {
        "StringEquals": {
          "iam:PermissionsBoundary": "arn:aws:iam::${ACCOUNT_ID}:policy/${PROJECT}-task-boundary"
        }
      }
    },
    {
      "Sid": "TagTaskRolesProjectTagOnly",
      "Effect": "Allow",
      "Action": [
        "iam:TagRole",
        "iam:UntagRole"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/${PROJECT}-task-*",
      "Condition": {
        "ForAllValues:StringEquals": {
          "aws:TagKeys": [
            "project"
          ]
        }
      }
    },
    {
      "Sid": "PassOnlyTaskRolesToEcs",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/${PROJECT}-task-*",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ecs-tasks.amazonaws.com"
        }
      }
    },
    {
      "Sid": "TeardownTaskDefinitions",
      "Effect": "Allow",
      "Action": "ecs:DeleteTaskDefinitions",
      "Resource": "arn:aws:ecs:${AWS_REGION}:${ACCOUNT_ID}:task-definition/${PROJECT}:*"
    },
    {
      "Sid": "TeardownTagQuery",
      "Effect": "Allow",
      "Action": "tag:GetResources",
      "Resource": "*"
    }
  ]
}
EOF2

aws iam create-policy --policy-name "${PROJECT}-deploy" \
  --policy-document file:///tmp/deploy-policy.json \
  --tags Key=project,Value="$PROJECT"
export POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${PROJECT}-deploy"
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
```

What the IAM statements are for:

- **`TaskRolesWithinBoundary`**: the deploy role can only create or change
  `${PROJECT}-task-*` roles that carry the boundary. Without that condition, a
  role that can create roles can create one more privileged than itself.
- **`TagTaskRolesProjectTagOnly`**: `iam:TagRole` and `iam:UntagRole` are in
  their own statement because the AWS Service Authorization Reference does not
  list `iam:PermissionsBoundary` as a condition key for them. Under `StringEquals`
  a missing key never matches, so they could never be allowed in the boundary
  statement. `CreateRole` with tags also needs `iam:TagRole`, and
  `default_tags` always sends tags. Only the `project` tag key is allowed.
- **`PassOnlyTaskRolesToEcs`**: without the `PassedToService` condition, an
  unconstrained `PassRole` lets the holder become anything.
- **`TeardownTaskDefinitions` and `TeardownTagQuery`**: used by `destroy.yml`
  to delete deregistered task definitions and to run the final tag query.
- **`ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer`**: `docker push`
  checks the uploaded manifest with a `HEAD` request, which needs them.

Every API the deployment calls is listed in
`aidlc-docs/construction/reference-deployment/infrastructure-design/infrastructure-design.md`,
section 4. If the code changes, Terraform reports each missing action as an
`AccessDenied` naming the API. Add the action with `aws iam create-policy-version
--set-as-default`. This keeps the previous version available for rollback, and
policies hold at most 5 versions.

- [ ] Boundary policy created
- [ ] Deploy policy created and attached to the deploy role

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

The service admits HTTP from one operator address only. That address is a
**secret**, not a variable. GitHub masks secret values in every log line,
including `terraform plan` output, and Actions logs are public on a public
repository.

```bash
gh secret set OPERATOR_CIDR --body "<YOUR_PUBLIC_IP>/32" --repo "${GH_OWNER}/${GH_REPO}"
```

It must be a single `/32`. Terraform rejects anything wider, including
`0.0.0.0/0`. Find your address with `curl -s https://checkip.amazonaws.com`. If it
changes, for example when you move network, update the secret and run Deploy
again.

- [ ] Variables set
- [ ] `OPERATOR_CIDR` secret set

## Verification

Run `.github/workflows/verify-oidc.yml`. It probes each policy statement and
**asserts the role cannot list IAM users**. That negative check is the only one
that distinguishes a scoped policy from an administrator policy.

- [ ] All steps pass

## Removal

Nothing here is created by Terraform. No `destroy` removes any of it.

```bash
aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
aws iam delete-role --role-name "$ROLE_NAME"

# A policy with extra versions cannot be deleted, so remove the non-default
# versions first
for arn in "$POLICY_ARN" "$BOUNDARY_ARN"; do
  for v in $(aws iam list-policy-versions --policy-arn "$arn" \
      --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$v"
  done
  aws iam delete-policy --policy-arn "$arn"
done
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
gh secret delete OPERATOR_CIDR --repo "${GH_OWNER}/${GH_REPO}"
```

Run the **Destroy** workflow first (see `docs/deploy.md`). It needs the role and
the state bucket, so it cannot run after they are removed.

Delete the identity provider only if nothing else in the account uses it.

```bash
aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=project,Values=$PROJECT" \
  --query 'ResourceTagMappingList[].ResourceARN'
```

- [ ] Teardown run and verified empty
