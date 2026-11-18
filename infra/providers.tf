# Region comes from the AWS_REGION environment variable (vars.AWS_REGION in CI,
# the operator's shell locally), so no region is written in this repository.
provider "aws" {
  default_tags {
    tags = {
      # One project tag on everything, so teardown can be verified by a tag query.
      project = var.project
    }
  }
}
