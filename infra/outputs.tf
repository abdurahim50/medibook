output "api_url" {
  description = "Base URL of the API (HTTP, restricted to allowed_cidrs)."
  value       = "http://${aws_lb.api.dns_name}"
}

output "ecr_repository_url" {
  description = "Push the image here."
  value       = data.aws_ecr_repository.api.repository_url
}

output "log_group" {
  description = "CloudWatch log group for the API, including audit events."
  value       = aws_cloudwatch_log_group.api.name
}

output "ecs_cluster" {
  value = aws_ecs_cluster.main.name
}

output "alarms" {
  description = "CloudWatch alarms that notify the alert topic."
  value = [
    aws_cloudwatch_metric_alarm.denied.alarm_name,
    aws_cloudwatch_metric_alarm.no_healthy_targets.alarm_name,
  ]
}

output "db_endpoint" {
  description = "Private database endpoint (reachable only from the API tasks)."
  value       = aws_db_instance.main.address
}

output "db_secret_arn" {
  description = "Secrets Manager secret holding the database credentials (managed by RDS)."
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}
