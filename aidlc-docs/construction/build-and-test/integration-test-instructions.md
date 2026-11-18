# Integration and End-to-End Test Instructions

There is one unit, so "integration" here means the pieces working together: the image, Terraform, AWS, and the GitHub Actions workflows. There are two levels.

## Level 1: local container smoke test (no AWS)

The container is published on **loopback only**:
```bash
docker build -t aidlc-demo:smoke app/
cid=$(docker run -d --rm -p 127.0.0.1:18080:8080 aidlc-demo:smoke)
curl -i http://127.0.0.1:18080/           # expect 200 and the fixed line
docker exec "$cid" id                      # expect uid=101(nginx)
docker stop "$cid"
```
Result on 2026-11-18:
- `HTTP/1.1 200 OK`, with the body `Hello from aidlc-demo: deployed through GitHub Actions by an AI-DLC workflow.`;
- running as `uid=101(nginx)`;
- listening on `127.0.0.1:18080` only.

## Level 2: live deployment (operator-run, not yet done)

**Setup**:
- complete `docs/prerequisites.md`, including the new `OPERATOR_CIDR` secret and the deploy-policy check in §4;
- commit and push to `main`. That is your decision; I have committed nothing.

| # | Scenario | Steps | Expected | Proves |
|---|---|---|---|---|
| L2.1 | Pull-request checks | Open a pull request with any change | `pr-checks` is green with no AWS credentials | FR-7, NFR-1 |
| L2.2 | First deploy on an empty account | `gh workflow run deploy.yml --ref main` | Creates ECR, pushes `:<sha>`, prints a scan summary, applies, the service is stable on this SHA, prints `Service address: http://<ip>:8080/`, the runner is refused | FR-8, success criterion 2 |
| L2.3 | Operator reaches it | `curl http://<ip>:8080/` from the operator machine | The fixed line | FR-1, success criterion 2 |
| L2.4 | Anyone else is refused | Automatic in L2.2, final step | `correctly unreachable from the runner` | NFR-3, Q2 |
| L2.5 | Re-run the same commit | Run deploy again | The build is skipped as the image already exists, and the plan shows no changes | Idempotence, immutable tags |
| L2.6 | Masking | Read the L2.2 log | No account id and no operator IP in plain text; they show as `***` | NFR-2 |
| L2.7 | Teardown | `gh workflow run destroy.yml --ref main -f confirm=aidlc-demo` | Destroy succeeds, INACTIVE task definitions are deleted, the plan exits 0, and the tag query shows nothing created by Terraform | FR-9, success criterion 5 |
| L2.8 | Hand-made removal | `docs/prerequisites.md` Removal | The role, policies, provider, bucket and variables are gone | Vision §8 |

**Cleanup**: L2.7 and L2.8 are the cleanup. Record the run URLs and the final tag query in `aidlc-docs/audit.md`.

**Most likely first failure**: `AccessDenied` on `iam:TagRole` while creating the execution role. See `docs/prerequisites.md` §4.
