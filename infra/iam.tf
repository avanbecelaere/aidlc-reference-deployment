data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  # Built at plan time so no account id is written in this repository.
  permissions_boundary_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${var.permissions_boundary_name}"
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # Only ECS acting for this account may assume the role (confused deputy).
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# The task execution role: what ECS itself uses to pull the image and write logs.
# There is deliberately no task role, because the container calls no AWS APIs.
#
# The name must start with "<project>-task-" and the role must carry the
# boundary: the hand-made deploy policy only allows creating roles that do both
# (docs/prerequisites.md section 4).
resource "aws_iam_role" "task_execution" {
  name                 = "${var.project}-task-execution"
  description          = "ECS task execution role for ${var.project}: ECR pull and log writes"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
  permissions_boundary = local.permissions_boundary_arn
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
