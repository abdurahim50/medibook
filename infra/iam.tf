data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# Execution roles: used by ECS itself to pull the image, write logs and inject
# secrets at start. There are two (F-8): the API's can read no secret at all;
# only the migration task's can read the admin credentials. A task definition
# that names the API execution role, whoever registers it, cannot obtain them.
# The API service's own task role (below) can do one thing only: sign in to the
# database as medibook_app.
resource "aws_iam_role" "execution" {
  name               = "${local.name}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource-level permissions
  }

  statement {
    sid       = "EcrPull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [data.aws_ecr_repository.api.arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.api.arn}:*"]
  }

}

resource "aws_iam_role_policy" "execution" {
  name   = "execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# ---------- Migration execution role: the only holder of the admin credentials ----------

resource "aws_iam_role" "migrate_execution" {
  name               = "${local.name}-migrate-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "migrate_execution" {
  # Same image and log access as the API, plus the two secrets.
  source_policy_documents = [data.aws_iam_policy_document.execution.json]

  statement {
    sid       = "SeedPassword"
    actions   = ["ssm:GetParameters"]
    resources = [local.seed_password_arn]
  }

  # The admin credentials RDS keeps in Secrets Manager.
  statement {
    sid       = "DatabaseSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.main.master_user_secret[0].secret_arn]
  }

  statement {
    sid       = "DecryptDatabaseSecret"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.db.arn]
  }
}

resource "aws_iam_role_policy" "migrate_execution" {
  name   = "execution"
  role   = aws_iam_role.migrate_execution.id
  policy = data.aws_iam_policy_document.migrate_execution.json
}

locals {
  seed_password_arn = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.seed_password_parameter}"
}

# ---------- Task role: the API service's only AWS permission ----------

resource "aws_iam_role" "api_task" {
  name               = "${local.name}-api-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "api_task" {
  # Sign in to PostgreSQL as medibook_app with an IAM token. "*" stands for the
  # instance's resource ID: a point-in-time restore creates a new one, and the
  # restored instance must accept the API without a policy change (drill 4).
  # The account, region and database user stay fixed.
  statement {
    sid       = "DatabaseConnectAsAppRole"
    actions   = ["rds-db:connect"]
    resources = ["arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:*/${local.db_app_user}"]
  }
}

resource "aws_iam_role_policy" "api_task" {
  name   = "database-connect"
  role   = aws_iam_role.api_task.id
  policy = data.aws_iam_policy_document.api_task.json
}
