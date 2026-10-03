output "api_url" {
  description = "Base URL of the API (HTTP, restricted to allowed_cidrs)."
  value       = "http://${aws_lb.api.dns_name}"
}

output "ecr_repository_url" {
  description = "Push the image here."
  value       = aws_ecr_repository.api.repository_url
}

output "log_group" {
  description = "CloudWatch log group for the API, including audit events."
  value       = aws_cloudwatch_log_group.api.name
}

output "ecs_cluster" {
  value = aws_ecs_cluster.main.name
}
