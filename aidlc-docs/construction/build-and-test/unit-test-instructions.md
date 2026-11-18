# Unit Test Execution

The unit tests are Terraform tests in `infra/tests/`, run against a **mocked AWS provider**. They need no credentials, make no AWS calls, and cost nothing.

## Run
```bash
terraform -chdir=infra init -backend=false
terraform -chdir=infra test
```

## Expected result
```text
tests/invariants.tftest.hcl... pass
tests/validation.tftest.hcl... pass
Success! 7 passed, 0 failed.
```

| File | Runs | What it proves |
|---|---|---|
| `validation.tftest.hcl` | 6 | A single `/32` is accepted. `0.0.0.0/0`, a `/24`, `0.0.0.0/32` and a malformed CIDR are rejected for `operator_cidr`. An invalid `project` is rejected. |
| `invariants.tftest.hcl` | 1 run, 12 assertions | Ingress is TCP 8080 from `operator_cidr` only. Egress is TCP 443 only. There are two subnets in two AZs. `assign_public_ip = true`. There is one Fargate task. The circuit breaker is on with rollback. X86_64. No task role. The boundary is attached. ECR tags are immutable with scan on push. Log retention is 1 day. |

## The tests can fail (mutation check, done 2026-11-18)
Each mutation was made on a throwaway copy of `infra/` and then discarded:

| Mutation | Result |
|---|---|
| `assign_public_ip = false` | `Failure! 6 passed, 1 failed`, with message "assign_public_ip must be true…" |
| Ingress `cidr_ipv4 = "0.0.0.0/0"` | `Failure! 6 passed, 1 failed`, with message "Ingress must come only from the operator address." |

## Coverage
There is no application code to measure line coverage on. The tests cover every security-relevant and failure-prone setting named in the requirements: NFR-3, FR-2.4, FR-3.1, FR-4.2, FR-4.3, FR-5.1, Q3 and Q4.

## If a test fails
1. Read the `error_message`. Each assertion names the invariant it protects.
2. If the change was intended, update the requirement first, through AI-DLC, and then the test.
3. Mock quirks:
   - the provider requires a 12-digit account id, which the mock builds with `format("%012d", 0)` so the account-id grep stays clean;
   - `aws_iam_policy_document.json` needs a valid JSON mock value.
