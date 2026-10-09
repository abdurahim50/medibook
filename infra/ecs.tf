resource "aws_cloudwatch_log_group" "api" {
  name              = "/${var.project}/${var.environment}/api"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "main" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "disabled" # enable for production; it adds cost
  }
}

locals {
  deploy      = var.image_digest != ""
  db_app_user = "medibook_app"

  # Database connection through the standard libpq variables. TLS with full
  # certificate and hostname verification against the RDS CA bundle in the image.
  db_environment = [
    { name = "PGHOST", value = aws_db_instance.main.address },
    { name = "PGPORT", value = tostring(aws_db_instance.main.port) },
    { name = "PGDATABASE", value = aws_db_instance.main.db_name },
    { name = "PGSSLMODE", value = "verify-full" },
    { name = "PGSSLROOTCERT", value = "/srv/certs/rds-global-bundle.pem" },
  ]
}

# Deploy only images signed by the release workflow on main. The check runs
# during every plan: if the signature or SBOM attestation does not verify, the
# script exits non-zero and the plan fails before anything is changed.
data "external" "image_signature" {
  count   = local.deploy ? 1 : 0
  program = ["bash", "${path.module}/../scripts/verify-image-terraform.sh"]
  query = {
    digest  = var.image_digest
    profile = var.aws_profile == null ? "" : var.aws_profile
    region  = var.region
  }
}

resource "aws_ecs_task_definition" "api" {
  count = local.deploy ? 1 : 0

  family                   = "${local.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.api_task.arn # rds-db:connect as medibook_app, nothing else

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # Writable scratch space: the root filesystem is read-only. Data lives in RDS.
  volume { name = "tmp" }

  container_definitions = jsonencode([{
    name      = "api"
    image     = "${data.aws_ecr_repository.api.repository_url}@${var.image_digest}"
    essential = true
    user      = "10001:10001"

    readonlyRootFilesystem = true
    linuxParameters = {
      capabilities = { add = [], drop = ["ALL"] }
    }

    # Run the API only. Schema and seed data come from the migration task below,
    # which holds the admin credentials (F-8). Proxy headers let the audit log and
    # rate limiter see the real client address behind the ALB. Only the ALB's
    # subnets are trusted (MB-004): the ALB appends the client address to
    # X-Forwarded-For, so Uvicorn reads the list from the right and stops at the
    # first address outside these ranges. With "*" it took the leftmost entry,
    # which the client controls.
    command = [
      "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000",
      "--proxy-headers", "--forwarded-allow-ips=${join(",", aws_subnet.public[*].cidr_block)}"
    ]

    # hostPort, systemControls and volumesFrom are the values AWS stores by default.
    # Declaring them avoids a perpetual diff that would replace the task definition
    # on every plan.
    portMappings   = [{ containerPort = 8000, hostPort = 8000, protocol = "tcp" }]
    systemControls = []
    volumesFrom    = []

    # Least-privilege database role, signed in with a 15-minute IAM token
    # generated from the task role. No password and no secret in this task.
    environment = concat(local.db_environment, [
      { name = "PGUSER", value = local.db_app_user },
      { name = "MEDIBOOK_DB_IAM_AUTH", value = "1" },
      { name = "AWS_REGION", value = var.region },
    ])

    mountPoints = [
      { sourceVolume = "tmp", containerPath = "/tmp", readOnly = false },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.api.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "api"
      }
    }
  }])

  lifecycle {
    precondition {
      condition     = data.external.image_signature[0].result.verified == "true" && data.external.image_signature[0].result.digest == var.image_digest
      error_message = "The image signature was not verified for this digest; only images signed by release.yml on main can be deployed."
    }
  }
}

# ---------- Migration: one-off task with the admin credentials ----------
# Creates the schema, the medibook_app role and its grants, and the seed data.
# Run once after each deploy (docs/deployment.md); it exits when done. It is the
# only task definition that receives the admin credentials.

resource "aws_ecs_task_definition" "migrate" {
  count = local.deploy ? 1 : 0

  family                   = "${local.name}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "migrate"
    image     = "${data.aws_ecr_repository.api.repository_url}@${var.image_digest}"
    essential = true
    user      = "10001:10001"

    readonlyRootFilesystem = true
    linuxParameters = {
      capabilities = { add = [], drop = ["ALL"] }
    }

    command = ["python", "-m", "app.seed"]

    portMappings   = []
    systemControls = []
    volumesFrom    = []
    mountPoints    = []

    environment = concat(local.db_environment, [
      { name = "MEDIBOOK_APP_DB_USER", value = local.db_app_user },
    ])
    secrets = [
      { name = "MEDIBOOK_SEED_PASSWORD", valueFrom = local.seed_password_arn },
      { name = "PGUSER", valueFrom = "${aws_db_instance.main.master_user_secret[0].secret_arn}:username::" },
      { name = "PGPASSWORD", valueFrom = "${aws_db_instance.main.master_user_secret[0].secret_arn}:password::" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.api.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "migrate"
      }
    }
  }])

  lifecycle {
    precondition {
      condition     = data.external.image_signature[0].result.verified == "true" && data.external.image_signature[0].result.digest == var.image_digest
      error_message = "The image signature was not verified for this digest; only images signed by release.yml on main can be deployed."
    }
  }
}

resource "aws_ecs_service" "api" {
  count = local.deploy ? 1 : 0

  name             = "${local.name}-api"
  cluster          = aws_ecs_cluster.main.id
  task_definition  = aws_ecs_task_definition.api[0].arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true # no NAT gateway; inbound is still blocked by the task security group
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8000
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = 30

  depends_on = [aws_lb_listener.http]
}
