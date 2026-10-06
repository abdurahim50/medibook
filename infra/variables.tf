variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named AWS CLI profile used by Terraform. Null uses the default credential chain (environment variables in CI)."
  type        = string
  default     = null
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

variable "alarm_email" {
  description = "Email address subscribed to security and availability alarms. Empty creates the topic without a subscription."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.alarm_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alarm_email))
    error_message = "alarm_email must be a valid email address, or empty."
  }
}

# ---------- Database ----------

variable "db_instance_class" {
  description = "RDS instance size. db.t3.micro: db.t4g.micro (Graviton) hit InsufficientDBInstanceCapacity in us-east-1."
  type        = string
  default     = "db.t3.micro"
}

variable "db_multi_az" {
  description = "Standby replica in a second Availability Zone with automatic failover. Doubles the database cost; true in production."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "Days of automated backups and point-in-time recovery."
  type        = number
  default     = 7

  validation {
    condition     = var.db_backup_retention_days >= 7 && var.db_backup_retention_days <= 35
    error_message = "db_backup_retention_days must be between 7 and 35."
  }
}

variable "db_deletion_protection" {
  description = "Block deletion of the database. False in dev, where the environment is destroyed after each session; true in production."
  type        = bool
  default     = false
}
