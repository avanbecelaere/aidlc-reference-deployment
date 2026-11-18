# Input validation. Offline: the AWS provider is mocked, no credentials needed.
# Run: terraform -chdir=infra test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["zz-test-1a", "zz-test-1b", "zz-test-1c"] }
  }
  # The provider requires a 12-digit account id in ARNs, while the PR check
  # rejects any committed 12-digit number. format() builds one at test time.
  mock_data "aws_caller_identity" {
    defaults = { account_id = format("%012d", 0) }
  }
  # The default mock returns a random string; aws_iam_role needs valid JSON.
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "zz-test-1" }
  }
}

variables {
  operator_cidr = "203.0.113.10/32"
  image_tag     = "test"
}

run "accepts_single_address" {
  command = plan
}

run "rejects_whole_internet" {
  command = plan
  variables {
    operator_cidr = "0.0.0.0/0"
  }
  expect_failures = [var.operator_cidr]
}

run "rejects_wider_than_single_address" {
  command = plan
  variables {
    operator_cidr = "203.0.113.0/24"
  }
  expect_failures = [var.operator_cidr]
}

run "rejects_unspecified_address" {
  command = plan
  variables {
    operator_cidr = "0.0.0.0/32"
  }
  expect_failures = [var.operator_cidr]
}

run "rejects_malformed_cidr" {
  command = plan
  variables {
    operator_cidr = "not-an-address"
  }
  expect_failures = [var.operator_cidr]
}

run "rejects_bad_project_name" {
  command = plan
  variables {
    project = "Not_Valid"
  }
  expect_failures = [var.project]
}
