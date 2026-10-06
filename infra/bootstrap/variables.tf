variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named AWS CLI profile used by Terraform."
  type        = string
  default     = "default"
}

variable "project" {
  description = "Project name."
  type        = string
  default     = "medibook"
}

variable "github_repository" {
  description = "GitHub repository (owner/name) allowed to publish images."
  type        = string
  default     = "abdurahim50/medibook"
}

variable "release_branch" {
  description = "Only workflows running on this branch can assume the release role."
  type        = string
  default     = "main"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider here. Default false: the provider is an account-level resource owned by the aws-account-baseline stack, and this stack only references it."
  type        = bool
  default     = false
}
