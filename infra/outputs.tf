output "cluster_name" {
  description = "ECS cluster name, for looking up the running task."
  value       = aws_ecs_cluster.main.name
}

output "service_name" {
  description = "ECS service name, for looking up the running task."
  value       = aws_ecs_service.app.name
}

output "ecr_repository_url" {
  description = "ECR repository URL. Contains the account id; masked in CI logs."
  value       = aws_ecr_repository.app.repository_url
}

output "log_group_name" {
  description = "CloudWatch log group receiving the container's logs."
  value       = aws_cloudwatch_log_group.app.name
}
