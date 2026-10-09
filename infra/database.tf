# RDS PostgreSQL: private, encrypted, backed up, password never seen by Terraform.
#
#   - Private subnets with no route to the internet; the only inbound path is
#     PostgreSQL from the API tasks' security group.
#   - Storage, backups and the generated master password encrypted with a
#     customer-managed KMS key.
#   - RDS generates the master password and keeps it in Secrets Manager
#     (manage_master_user_password), so it never appears in Terraform code,
#     variables or state. ECS injects it into the task at start.
#   - Automated backups with point-in-time recovery; TLS required for every
#     connection; connections, slow queries and schema changes (DDL) logged to
#     CloudWatch.
#   - Two database roles (finding F-8): the admin above owns the schema and is
#     used only by the one-off migration task; the API signs in as medibook_app
#     (row access only) with a 15-minute IAM token, so it has no password at all.

# ---------- Private subnets for the database ----------

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 100 + count.index)

  tags = { Name = "${local.name}-private-${local.azs[count.index]}" }
}

# A route table with no default route: nothing in these subnets can reach, or
# be reached from, the internet.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-private" }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_db_subnet_group" "main" {
  name       = local.name
  subnet_ids = aws_subnet.private[*].id
}

# ---------- Network access: API tasks only ----------

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "PostgreSQL: from the API tasks only"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_tasks" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the API tasks"
  referenced_security_group_id = aws_security_group.task.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "task_to_db" {
  security_group_id            = aws_security_group.task.id
  description                  = "PostgreSQL to the database only"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

# ---------- Encryption key for data at rest and the password secret ----------

data "aws_iam_policy_document" "db_key" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"] # in a key policy, "*" means this key only
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "db" {
  description             = "${local.name} database storage, backups and credentials"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.db_key.json
}

resource "aws_kms_alias" "db" {
  name          = "alias/${local.name}-db"
  target_key_id = aws_kms_key.db.key_id
}

# ---------- Server settings ----------

resource "aws_db_parameter_group" "main" {
  name        = "${local.name}-postgres17"
  family      = "postgres17"
  description = "MediBook: TLS required; connections, slow statements and DDL logged"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot" # how RDS stores this parameter; avoids a diff on every plan
  }
  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }
  # Schema changes (CREATE, ALTER, DROP) are logged; the destructive-SQL alarm
  # reads them (F-7).
  parameter {
    name  = "log_statement"
    value = "ddl"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # milliseconds; statements slower than this are logged
  }
  # Never write bind parameters (emails, password hashes) to the log (MB-006).
  # PostgreSQL's default (-1) logs them in full with slow statements.
  parameter {
    name  = "log_parameter_max_length"
    value = "0"
  }
  parameter {
    name  = "log_parameter_max_length_on_error"
    value = "0"
  }
}

# RDS creates this log group on first export without a retention period, so it
# is created here first with one (MB-POL-05).
resource "aws_cloudwatch_log_group" "db" {
  name              = "/aws/rds/instance/${local.name}/postgresql"
  retention_in_days = var.log_retention_days
}

# ---------- The database ----------

resource "aws_db_instance" "main" {
  identifier     = local.name
  engine         = "postgres"
  engine_version = "17"
  instance_class = var.db_instance_class

  db_name  = "medibook"
  username = "medibook_admin"
  port     = 5432

  # RDS generates the password and stores it in Secrets Manager, encrypted with
  # the key above. Terraform never knows it.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.db.key_id

  # The API's role signs in with IAM tokens (rds-db:connect), not a password.
  iam_database_authentication_enabled = true

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = aws_kms_key.db.arn

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az
  parameter_group_name   = aws_db_parameter_group.main.name

  # Automated daily snapshots plus transaction logs: restore to any second
  # within the retention period (point-in-time recovery).
  backup_retention_period = var.db_backup_retention_days
  backup_window           = "08:00-08:30" # UTC, 03:00-03:30 Central
  maintenance_window      = "sun:09:00-sun:09:30"
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade      = true
  enabled_cloudwatch_logs_exports = ["postgresql"]

  # Dev environment is destroyed after each session. In production these are
  # true / false / a final snapshot name.
  deletion_protection      = var.db_deletion_protection
  skip_final_snapshot      = true
  delete_automated_backups = true

  depends_on = [aws_cloudwatch_log_group.db]
}
