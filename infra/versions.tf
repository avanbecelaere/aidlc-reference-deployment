terraform {
  # 1.10 is the first release with S3-native state locking (use_lockfile).
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial backend configuration. Deliberately empty: the state bucket name
  # contains the AWS account id and this repository is public. Values are
  # supplied at init time:
  #   terraform init -backend-config=backend.hcl
  # backend.hcl is gitignored; see backend.hcl.example for its shape. In CI the
  # deploy and destroy workflows write it on the runner.
  backend "s3" {}
}
