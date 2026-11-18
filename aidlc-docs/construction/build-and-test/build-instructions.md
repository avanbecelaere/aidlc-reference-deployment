# Build Instructions

## Prerequisites
| Tool | Version | Used for |
|---|---|---|
| Terraform | `>= 1.10`. CI pins 1.17.2; verified locally with 1.16.3. | `fmt`, `validate`, `test`, `init`, `plan`, `apply` |
| Docker | Any version with BuildKit | Building the image |
| git | Any | Account-id grep (`git grep`) |
| AWS provider | 6.73.0, pinned by `infra/.terraform.lock.hcl` | Downloaded by `terraform init` |

The static checks need no environment variables and no AWS credentials.

## Build Steps

### 1. Install dependencies
```bash
terraform -chdir=infra init -backend=false
```
This downloads the AWS provider, verified against the hashes in the committed lock file. `infra/.terraform/` is gitignored.

### 2. Build the container image
```bash
docker build --platform linux/amd64 -t aidlc-demo:local app/
```
The amd64 build works on an arm64 host without emulation, because the Dockerfile has no `RUN` steps. *Running* the amd64 image on arm64 does need emulation. For a local smoke test, build without `--platform` instead (see the integration test instructions).

### 3. Validate the Terraform
```bash
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra validate
```

### 4. Verify success
- `fmt` prints nothing and exits 0.
- `validate` prints `Success! The configuration is valid.`
- `docker build` ends with `naming to docker.io/library/aidlc-demo:local done`.
- Artifacts: a local image `aidlc-demo:local`. The real image is built and pushed only by `deploy.yml`, tagged with the commit SHA.

## In CI
`pr-checks.yml` runs steps 1 to 3, plus the unit tests and the account-id grep, on every pull request with no credentials. `deploy.yml` repeats the build and pushes to ECR.

## Troubleshooting
| Symptom | Cause | Fix |
|---|---|---|
| `init` reports that the checksums don't match the lock file | Provider downloaded for a platform not in the lock | `terraform -chdir=infra providers lock -platform=<os_arch>`, then commit the lock file |
| `Blocks of type "run" are not expected` | A syntax error in a `.tftest.hcl` file, typically an unclosed brace, makes `init` fail too | Fix the brace. This happened once during generation. |
| `exec format error` when running the image | An amd64 image run on an arm64 host | Build without `--platform` for local runs |
