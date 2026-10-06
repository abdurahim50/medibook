output "ecr_repository_url" {
  description = "Image repository the release workflow publishes to."
  value       = aws_ecr_repository.api.repository_url
}

output "release_role_arn" {
  description = "Set as the AWS_RELEASE_ROLE_ARN repository variable in GitHub."
  value       = aws_iam_role.release.arn
}

output "plan_role_arn" {
  description = "Set as the AWS_PLAN_ROLE_ARN repository variable in GitHub."
  value       = aws_iam_role.plan.arn
}
