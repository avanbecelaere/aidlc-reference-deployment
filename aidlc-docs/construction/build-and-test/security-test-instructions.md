# Security Test Instructions

| Check | Where it runs | Command / step | Expected | Status |
|---|---|---|---|---|
| No account ids in the repository | Local and `pr-checks` | `git grep --untracked -nE '(^\|[^0-9A-Za-z])[0-9]{12}([^0-9A-Za-z]\|$)'` | No output | Passed locally |
| No ARNs, bucket names or IPs | Local | Code Generation step 17 greps | None outside the documentation ranges and VPC CIDRs | Passed |
| Ingress is a single `/32` | Local and `pr-checks` | `terraform test` | Passes, and the mutation check shows it fails if widened | Passed |
| Actions pinned to SHAs, explicit `permissions` | Local | `actionlint`, plus the grep in step 17 | Clean | Passed (`actionlint` 1.7.12: 0 findings in the new workflows) |
| Container runs as non-root | Local | `docker exec <id> id` | `uid=101(nginx)` | Passed |
| Others are refused by the live endpoint | `deploy.yml`, final step | Runner `curl`, which must get no response | `correctly unreachable from the runner` | Pending (live) |
| Masking in logs | Live | Read the deploy log | The account id and the operator IP show as `***` | Pending (live) |
| Base image CVEs | `deploy.yml` | ECR basic scan, summary printed | Reviewed by a human; it does not block the deploy | Pending (live) |
| Teardown leaves nothing | `destroy.yml`, plus the hand-made removal | Plan exit code 0, tag query | Nothing Terraform-created remains | Pending (live) |

`actionlint` also reports two info-level shellcheck notes in the pre-existing `verify-oidc.yml`: SC2016 on a JMESPath backtick, and SC2086 on an intentional word-split loop. Both are intentional, and that file is unchanged.
