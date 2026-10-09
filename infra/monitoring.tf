# Observe: alarms on the signals that matter most for this service.
#   1. Security: denied requests in the audit log (cross-patient reads, sign-in throttling).
#   2. Availability: no healthy API task behind the load balancer.
#   3. Data: destructive SQL (DROP, TRUNCATE) in the database log (finding F-7).
#   4. Data: the API cannot reach the database (finding F-12).

# ---------- Alert topic (encrypted with a customer-managed key) ----------
# CloudWatch cannot publish to a topic encrypted with the AWS-managed SNS key,
# so the topic uses its own key that grants CloudWatch access.

data "aws_iam_policy_document" "alerts_key" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"] # in a key policy, "*" means this key only
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchPublish"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_kms_key" "alerts" {
  description             = "${local.name} alert topic encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.alerts_key.json
}

resource "aws_kms_alias" "alerts" {
  name          = "alias/${local.name}-alerts"
  target_key_id = aws_kms_key.alerts.key_id
}

resource "aws_sns_topic" "alerts" {
  name              = "${local.name}-alerts"
  kms_master_key_id = aws_kms_key.alerts.arn
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "CloudWatchAlarmsPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------- Security signal: denied requests from the audit log ----------

resource "aws_cloudwatch_log_metric_filter" "denied" {
  name           = "${local.name}-audit-denied"
  log_group_name = aws_cloudwatch_log_group.api.name
  pattern        = "{ ($.type = \"audit\") && ($.outcome = \"denied\") }"

  metric_transformation {
    name          = "AuditDenied"
    namespace     = "MediBook/${var.environment}"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "denied" {
  alarm_name          = "${local.name}-security-denied-requests"
  alarm_description   = "Denied requests (cross-patient reads or sign-in throttling) in the audit log. Possible probing or credential stuffing. See docs/runbook.md."
  namespace           = "MediBook/${var.environment}"
  metric_name         = "AuditDenied"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ---------- Availability signal: no healthy task behind the ALB ----------

resource "aws_cloudwatch_metric_alarm" "no_healthy_targets" {
  alarm_name          = "${local.name}-api-no-healthy-targets"
  alarm_description   = "No healthy API task behind the load balancer. Patients cannot book. See docs/runbook.md."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching" # no data from the target group means nothing is serving

  dimensions = {
    LoadBalancer = aws_lb.api.arn_suffix
    TargetGroup  = aws_lb_target_group.api.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ---------- Data signal: destructive SQL in the database log ----------
# Matches on markers PostgreSQL writes the same way however the SQL was spelled
# (MB-007: patterns are case-sensitive, SQL is not):
#   - DESTRUCTIVE_SQL: warnings from an event trigger on every dropped table or
#     schema, and from a trigger on every TRUNCATE (app/db.py);
#   - "must be owner of", "permission denied for": attempts the database refused,
#     such as the API's role trying to drop or alter a table.
# The statement phrases stay as a fallback if the event trigger is missing.

resource "aws_cloudwatch_log_metric_filter" "destructive_sql" {
  name           = "${local.name}-db-destructive-sql"
  log_group_name = aws_cloudwatch_log_group.db.name
  pattern        = "?DESTRUCTIVE_SQL ?\"must be owner of\" ?\"permission denied for\" ?\"DROP TABLE\" ?\"drop table\" ?\"DROP DATABASE\" ?\"drop database\""

  metric_transformation {
    name          = "DestructiveSql"
    namespace     = "MediBook/${var.environment}"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "destructive_sql" {
  alarm_name          = "${local.name}-db-destructive-sql"
  alarm_description   = "DROP or TRUNCATE in the database log. Possible data loss or a compromised identity. See docs/runbook.md."
  namespace           = "MediBook/${var.environment}"
  metric_name         = "DestructiveSql"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ---------- Data signal: the API cannot reach the database ----------
# /health no longer checks the database (F-6), so a database outage leaves the
# load balancer healthy and the no-healthy-targets alarm silent (F-12). The API
# logs every failed readiness check, and an unhandled database error writes a
# psycopg.OperationalError traceback, so either one counts here.
# Limit: it needs traffic or someone calling /ready; production adds a
# synthetic check (CloudWatch Synthetics or Route 53) that calls /ready.

resource "aws_cloudwatch_log_metric_filter" "database_unreachable" {
  name           = "${local.name}-api-database-unreachable"
  log_group_name = aws_cloudwatch_log_group.api.name
  pattern        = "?\"readiness check failed\" ?\"psycopg.OperationalError\" ?\"psycopg.errors.ConnectionTimeout\""

  metric_transformation {
    name          = "DatabaseUnreachable"
    namespace     = "MediBook/${var.environment}"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "database_unreachable" {
  alarm_name          = "${local.name}-api-database-unreachable"
  alarm_description   = "The API cannot reach the database (readiness failures or connection errors). Patients cannot sign in or book. See docs/runbook.md."
  namespace           = "MediBook/${var.environment}"
  metric_name         = "DatabaseUnreachable"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
