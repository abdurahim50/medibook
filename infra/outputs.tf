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
    aws_cloudwatch_metric_alarm.destructive_sql.alarm_name,
    aws_cloudwatch_metric_alarm.database_unreachable.alarm_name,
  ]
}

output "db_endpoint" {
  description = "Private database endpoint (reachable only from the API tasks)."
  value       = aws_db_instance.main.address
}

output "db_secret_arn" {
  description = "Secrets Manager secret holding the admin database credentials (managed by RDS; migration task only)."
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}

output "migrate_network" {
  description = "Network configuration for running the migration task (aws ecs run-task --network-configuration)."
  value       = local.migrate_network
}

output "migrate_task_definition" {
  description = "Task definition family of the one-off migration task."
  value       = local.deploy ? aws_ecs_task_definition.migrate[0].family : null
}

output "alert_topic_arn" {
  description = "SNS topic the alarms notify; checked by scripts/check-alerting.sh."
  value       = aws_sns_topic.alerts.arn
}
