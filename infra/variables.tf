variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named AWS CLI profile used by Terraform."
  type        = string
  default     = "default"
}

variable "project" {
  description = "Project name, used in resource names and the Project tag."
  type        = string
  default     = "medibook"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "allowed_cidrs" {
  description = "Client CIDR blocks allowed to reach the load balancer. Use your own public IP (x.x.x.x/32) for a private demo."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0
    error_message = "Set at least one allowed CIDR, for example your public IP as x.x.x.x/32."
  }
}

variable "image_digest" {
  description = "Digest of the image in ECR to deploy (sha256:...). Empty creates the repository only, with no running service."
  type        = string
  default     = ""

  validation {
    condition     = var.image_digest == "" || can(regex("^sha256:[a-f0-9]{64}$", var.image_digest))
    error_message = "image_digest must look like sha256:<64 hex characters>."
  }
}

variable "desired_count" {
  description = "Number of API tasks to run."
  type        = number
  default     = 1
}

variable "seed_password_parameter" {
  description = "Name of the SSM SecureString parameter holding the demo password. Created outside Terraform so the value never enters state."
  type        = string
  default     = "/medibook/dev/seed-password"
}

variable "signin_rate_limit" {
  description = "WAF limit: sign-in requests per client IP in any 5-minute window."
  type        = number
  default     = 100
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the API log group."
  type        = number
  default     = 7
}
