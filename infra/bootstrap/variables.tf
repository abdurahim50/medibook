variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named AWS CLI profile used by Terraform. Null uses the default credential chain (environment variables in CI)."
  type        = string
  default     = null
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

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be in the form owner/name."
  }
}

# Immutable IDs: they never change on rename and are never reused.
# Find them with: gh api repos/OWNER/REPO --jq '.owner.id, .id'
variable "github_owner_id" {
  description = "Numeric ID of the GitHub account that owns the repository."
  type        = string
  default     = "45608947"

  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be numeric."
  }
}

variable "github_repository_id" {
  description = "Numeric ID of the GitHub repository."
  type        = string
  default     = "1396824993"

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id must be numeric."
  }
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
