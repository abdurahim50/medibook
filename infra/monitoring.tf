# Observe: alarms on the signals that matter most for this service.
#   1. Security: denied requests in the audit log (cross-patient reads, sign-in throttling).
#   2. Availability: no healthy API task behind the load balancer.
#   3. Data: destructive SQL (DROP, TRUNCATE) in the database log (finding F-7).

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
# log_statement = ddl logs every DROP; a trigger on each table raises a
# DESTRUCTIVE_SQL warning on TRUNCATE (app/db.py). Denied attempts by the API's
# role are logged with their statement too, so they also match. Patterns are
# case-sensitive, hence both spellings.

resource "aws_cloudwatch_log_metric_filter" "destructive_sql" {
  name           = "${local.name}-db-destructive-sql"
  log_group_name = aws_cloudwatch_log_group.db.name
  pattern        = "?\"DROP TABLE\" ?\"drop table\" ?\"DROP SCHEMA\" ?\"drop schema\" ?\"DROP DATABASE\" ?\"drop database\" ?DESTRUCTIVE_SQL"

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
