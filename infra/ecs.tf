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
  deploy = var.image_digest != ""
}

resource "aws_ecs_task_definition" "api" {
  count = local.deploy ? 1 : 0

  family                   = "${local.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # Writable scratch space: the root filesystem is read-only.
  volume { name = "data" }
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

    # Seed slots and demo patients on start, then run the API. Proxy headers let
    # the audit log and rate limiter see the real client address behind the ALB;
    # only the ALB can reach the task, so trusting forwarded headers is safe here.
    command = [
      "sh", "-c",
      "python -m app.seed && exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --proxy-headers --forwarded-allow-ips='*'"
    ]

    # hostPort, systemControls and volumesFrom are the values AWS stores by default.
    # Declaring them avoids a perpetual diff that would replace the task definition
    # on every plan.
    portMappings   = [{ containerPort = 8000, hostPort = 8000, protocol = "tcp" }]
    systemControls = []
    volumesFrom    = []

    environment = [{ name = "MEDIBOOK_DB", value = "/data/medibook.db" }]
    secrets     = [{ name = "MEDIBOOK_SEED_PASSWORD", valueFrom = local.seed_password_arn }]

    mountPoints = [
      { sourceVolume = "data", containerPath = "/data", readOnly = false },
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
