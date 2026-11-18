# Security- and correctness-relevant invariants of the planned infrastructure.
# Offline: the AWS provider is mocked, no credentials needed.
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

run "invariants" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.http_operator.cidr_ipv4 == var.operator_cidr
    error_message = "Ingress must come only from the operator address."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.http_operator.from_port == 8080 &&
      aws_vpc_security_group_ingress_rule.http_operator.to_port == 8080 &&
      aws_vpc_security_group_ingress_rule.http_operator.ip_protocol == "tcp"
    )
    error_message = "Ingress must be TCP 8080 only."
  }

  assert {
    condition = (
      aws_vpc_security_group_egress_rule.https_out.from_port == 443 &&
      aws_vpc_security_group_egress_rule.https_out.to_port == 443 &&
      aws_vpc_security_group_egress_rule.https_out.ip_protocol == "tcp"
    )
    error_message = "Egress must be TCP 443 only."
  }

  assert {
    condition     = length(aws_subnet.public) == 2 && aws_subnet.public[0].availability_zone != aws_subnet.public[1].availability_zone
    error_message = "There must be two public subnets in two different AZs."
  }

  assert {
    condition     = aws_ecs_service.app.network_configuration[0].assign_public_ip == true
    error_message = "assign_public_ip must be true, or the image pull fails (no NAT, no endpoints)."
  }

  assert {
    condition     = aws_ecs_service.app.desired_count == 1 && aws_ecs_service.app.launch_type == "FARGATE"
    error_message = "Exactly one Fargate task."
  }

  assert {
    condition = (
      aws_ecs_service.app.deployment_circuit_breaker[0].enable == true &&
      aws_ecs_service.app.deployment_circuit_breaker[0].rollback == true
    )
    error_message = "Deployment circuit breaker with rollback must be enabled."
  }

  assert {
    condition     = aws_ecs_task_definition.app.runtime_platform[0].cpu_architecture == "X86_64"
    error_message = "Runtime platform must be X86_64 to match the CI-built image."
  }

  assert {
    condition     = aws_ecs_task_definition.app.task_role_arn == null
    error_message = "No task role: the container calls no AWS APIs."
  }

  assert {
    condition     = endswith(aws_iam_role.task_execution.permissions_boundary, ":policy/${var.permissions_boundary_name}")
    error_message = "The execution role must carry the permissions boundary."
  }

  assert {
    condition = (
      aws_ecr_repository.app.image_tag_mutability == "IMMUTABLE" &&
      aws_ecr_repository.app.image_scanning_configuration[0].scan_on_push == true
    )
    error_message = "ECR tags must be immutable and images scanned on push."
  }

  assert {
    condition     = aws_cloudwatch_log_group.app.retention_in_days == 1
    error_message = "Log retention must be 1 day."
  }
}
