# Build and Test Summary

Date: 2026-11-18. Unit: `reference-deployment`.

## Build Status
| Item | Result |
|---|---|
| `terraform fmt -check -recursive` | Pass |
| `terraform validate` | Pass (`Success! The configuration is valid.`) |
| `docker build --platform linux/amd64 app/` | Pass |
| Provider lock | `hashicorp/aws` 6.73.0, for linux and darwin on amd64 and arm64 |
| Tools | Terraform 1.16.3 locally (CI pins 1.17.2), Docker with buildx 0.12.2, actionlint 1.7.12 |

## Test Execution Summary

### Unit tests (`terraform test`, mocked provider)
- **7 runs: 7 passed, 0 failed.** That is 6 validation cases, plus 1 invariants run with 12 assertions.
- **Mutation check:** turning off `assign_public_ip`, or widening ingress to `0.0.0.0/0`, each makes exactly one test fail with the intended message.
- **Fixed during this stage:** the first run failed on two **mock** issues, not on infrastructure defects. Both were fixed in `infra/tests/*.tftest.hcl`.
  - The policy-document mock returned non-JSON text.
  - The provider requires a 12-digit account id in ARNs. The mock now builds it with `format()`, so the account-id grep stays clean.

### Integration tests
- **Local container smoke test:** Pass. It returned 200 with the fixed body, as uid 101, published on loopback only.
- **Live deployment (L2.1 to L2.8):** **Not run.** It needs a commit and push to `main`, and the hand-made prerequisites, including the new `OPERATOR_CIDR` secret. See `integration-test-instructions.md`.

### Performance tests
- N/A by scope (vision §5). Rationale is in `performance-test-instructions.md`.

### Security tests
- **Passed locally:**
  - no account ids, ARNs, bucket names or IPs in the repository;
  - ingress limited to a single `/32` (tested, with the mutation check);
  - every action pinned to a SHA, with explicit `permissions`;
  - `actionlint` clean on the new workflows, after one SC2086 directive was added for an intentional word split in `deploy.yml`;
  - the container runs as non-root.
- **Pending live:** the runner denial probe, masking in the logs, the ECR scan, and teardown verification.

## Overall Status
- **Build:** Success.
- **All tests runnable without AWS:** Pass.
- **Ready for the live deployment:** Yes, once the operator:
  1. adds the `OPERATOR_CIDR` secret;
  2. checks the deploy policy against infrastructure-design §4, and especially the likely `iam:TagRole`/`DeleteRole` gap;
  3. commits and pushes.

## Success Criteria (vision §4) Status
| # | Criterion | Status |
|---|---|---|
| 1 | Every stage approved and recorded in `audit.md` | Met through Build and Test, pending this approval |
| 2 | The service answers after a GitHub Actions deployment | Pending: L2.2 and L2.3 |
| 3 | A reader can follow the chain from vision to the running task | In place: `aidlc-docs/`, then the commit, the image tag and the task definition |
| 4 | A second engineer can reproduce it from `docs/prerequisites.md` | Documented in `docs/prerequisites.md` and `docs/deploy.md`. Not yet proven by a second engineer. |
| 5 | Teardown is verified | Pending: L2.7 and L2.8 |
