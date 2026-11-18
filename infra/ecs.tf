data "aws_region" "current" {}

resource "aws_cloudwatch_log_group" "app" {
  # Named under /<project> so it falls inside the deploy policy's
  # log-group:/aidlc-demo* resource scope.
  name              = "/${var.project}/app"
  retention_in_days = 1
}

resource "aws_ecs_cluster" "main" {
  name = var.project

  # Stated explicitly: monitoring is out of scope (docs/vision.md section 5).
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_task_definition" "app" {
  family                   = var.project
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.task_execution.arn
  # No task_role_arn: the container makes no AWS API calls.

  # Stated, not defaulted. The image is built in CI on x86_64 runners; a default
  # that matches one machine but not another is the failure people copying this
  # hit first (docs/prerequisites.md, Container architecture).
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        { containerPort = 8080, protocol = "tcp" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "app"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "app" {
  name             = var.project
  cluster          = aws_ecs_cluster.main.id
  task_definition  = aws_ecs_task_definition.app.arn
  desired_count    = 1
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  network_configuration {
    subnets         = aws_subnet.public[*].id
    security_groups = [aws_security_group.service.id]

    # Load-bearing. With no NAT gateway and no VPC endpoints, the task reaches
    # ECR and CloudWatch Logs only through the internet gateway, using this
    # address. Without it the image pull fails with an error that reads like a
    # registry problem rather than a networking one.
    assign_public_ip = true
  }

  # A task that cannot pull or start fails the deployment and rolls back,
  # instead of retrying forever while Terraform reports success.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true

  # The deploy workflow waits with `aws ecs wait services-stable` instead, which
  # lets it print the stopped-task reason when a deployment fails.
  wait_for_steady_state = false
}
