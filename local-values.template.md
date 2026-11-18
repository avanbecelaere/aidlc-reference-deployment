# Local values

Copy this file to `local-values.md` and fill it in. That filename is gitignored,
so your values stay out of the repository.

```bash
cp local-values.template.md local-values.md
```

Account ids are not secrets, but there is no reason to publish which account a
deployment ran in. Keeping them here is also what lets `docs/prerequisites.md`
stay a template anyone can follow.

---

## Account

| Thing | Value |
|---|---|
| Account id | |
| Region | |
| Project tag | |
| Profile or auth method | |

Authentication command for this account:

```
```

## GitHub

| Thing | Value |
|---|---|
| Owner | |
| Repository | |
| Default branch | |
| Visibility | |

## Named resources

| Thing | Value |
|---|---|
| State bucket | |
| State key | |
| OIDC provider ARN | |
| Deploy role name | |
| Deploy role ARN | |
| Deploy policy ARN | |
| Permissions boundary ARN | |

Backend block:

```hcl
terraform {
  backend "s3" {
    bucket       = ""
    key          = ""
    region       = ""
    encrypt      = true
    use_lockfile = true
  }
}
```

## The observed OIDC subject

Do not fill this in from an example. Create the role, run the workflow once, and
read the rejected or accepted subject from CloudTrail.

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 10 --query 'Events[].CloudTrailEvent' --output text
```

Read `userIdentity.userName`.

| Thing | Value |
|---|---|
| Observed subject | |
| Shape (older or newer) | |
| Date observed | |

## Container architecture

| Thing | Value |
|---|---|
| Workstation architecture | |
| Build location (CI or local) | |
| Task definition runtime platform | |

## Progress

- [ ] Pre-flight checks run
- [ ] State bucket created, private, versioned, encrypted
- [ ] OIDC identity provider created or reused
- [ ] Deploy role created
- [ ] Subject observed and pinned with `StringEquals`
- [ ] Permissions boundary created
- [ ] Deploy policy attached, both IAM conditions present
- [ ] Repository variables set
- [ ] `verify-oidc` workflow passes, including the negative assertion
- [ ] First `terraform apply` succeeded
- [ ] Teardown run and verified empty on:

## Notes

Anything account-specific worth remembering: quota limits hit, actions added to
the policy during iteration, deviations from the documented steps.
