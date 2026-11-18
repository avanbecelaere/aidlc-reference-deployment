# Security Test Instructions

| Check | Where it runs | Command / step | Expected | Status |
|---|---|---|---|---|
| No account ids in the repository | Local and `pr-checks` | `git grep --untracked -nE '(^\|[^0-9A-Za-z])[0-9]{12}([^0-9A-Za-z]\|$)'` | No output | Passed locally |
| No ARNs, bucket names or IPs | Local | Code Generation step 17 greps | None outside the documentation ranges and VPC CIDRs | Passed |
| Ingress is a single `/32` | Local and `pr-checks` | `terraform test` | Passes, and the mutation check shows it fails if widened | Passed |
| Actions pinned to SHAs, explicit `permissions` | Local | `actionlint`, plus the grep in step 17 | Clean | Passed (`actionlint` 1.7.12: 0 findings in the new workflows) |
| Container runs as non-root | Local | `docker exec <id> id` | `uid=101(nginx)` | Passed |
| Others are refused by the live endpoint | `deploy.yml`, final step | Runner `curl`, which must get no response | `correctly unreachable from the runner` | Passed (runs 44344921218, 44348722672) |
| Masking in logs | Live | Read the deploy log | The account id and the operator IP show as `***` | **Partly met.** The operator IP is masked everywhere. The account id is masked after the mask step, but it appears once per run in the `role-to-assume` input echo, which comes from an unmasked variable. The user accepted this. |
| Base image CVEs | `deploy.yml` | ECR basic scan, summary printed | Reviewed by a human; it does not block the deploy | **Not working.** The runner's Docker pushes an OCI image index with an attestation manifest. ECR reports `ScanNotFoundException` for the tag. The step is non-gating, so deploys are unaffected. The likely fix is `--provenance=false`; it has not been tried. |
| Teardown leaves nothing | `destroy.yml`, plus the hand-made removal | Destroy-plan exit code 0, tag query | Nothing Terraform-created remains | **Terraform part passed** (run 44349622037, checked directly with read-only calls). The hand-made removal is deferred by the user. |

`actionlint` also reports two info-level shellcheck notes in the pre-existing `verify-oidc.yml`: SC2016 on a JMESPath backtick, and SC2086 on an intentional word-split loop. Both are intentional, and that file is unchanged.
