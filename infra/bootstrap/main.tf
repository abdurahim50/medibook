# Long-lived resources that outlive each dev session: the image registry and the
# identity CI uses to publish to it. The environment stack in ../ is created and
# destroyed per session and reads the repository from here.

data "aws_caller_identity" "current" {}

# ---------- GitHub Actions OIDC identity provider ----------
# Lets workflows exchange a short-lived GitHub token for AWS credentials.
# No AWS access keys are stored in GitHub.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
  github_owner             = split("/", var.github_repository)[0]
  github_repo              = split("/", var.github_repository)[1]
}

# ---------- Image registry ----------

resource "aws_ecr_repository" "api" {
  name = "${var.project}/api"

  # No tag can ever be overwritten. Cosign stores the signature and the SBOM
  # attestation under their own new tags (sha256-<digest>.sig / .att), so each
  # image is signed and attested exactly once, by the release workflow.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 10 most recent release images"
      selection = {
        tagStatus      = "tagged"
        tagPatternList = ["*"]
        countType      = "imageCountMoreThan"
        countNumber    = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ---------- Release role assumed by GitHub Actions ----------

data "aws_iam_policy_document" "release_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only this repository, and only workflows running on the release branch.
    # Pull requests and other branches cannot assume the role.
    # GitHub puts the immutable owner and repository IDs in the subject
    # (repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:...). Matching the IDs means a
    # deleted and re-created repository, or a released username claimed by
    # someone else, cannot assume this role even though the names match.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_subject_prefix}:ref:refs/heads/${var.release_branch}"]
    }
  }
}

resource "aws_iam_role" "release" {
  name                 = "${var.project}-github-release"
  description          = "Assumed by GitHub Actions on ${var.release_branch} to publish signed images to ECR"
  assume_role_policy   = data.aws_iam_policy_document.release_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "release" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource-level permissions
  }

  statement {
    sid = "PushAndSign"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      "ecr:ListImages",
    ]
    resources = [aws_ecr_repository.api.arn]
  }
}

resource "aws_iam_role_policy" "release" {
  name   = "publish-images"
  role   = aws_iam_role.release.id
  policy = data.aws_iam_policy_document.release.json
}

# ---------- Plan role assumed by GitHub Actions ----------
# Used by the "Terraform plan" CI job to plan both stacks on every pull request
# and check the plans against the Conftest policies. The job plans from an empty
# state, so this role needs no access to the state bucket (which holds sensitive
# values) and can change nothing: it reads the image repository (for signature
# verification) and the OIDC provider, and nothing else.

locals {
  github_subject_prefix = "repo:${local.github_owner}@${var.github_owner_id}/${local.github_repo}@${var.github_repository_id}"
}

data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Pull requests from this repository and pushes to main. Pull requests from
    # forks receive no OIDC token from GitHub.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${local.github_subject_prefix}:pull_request",
        "${local.github_subject_prefix}:ref:refs/heads/${var.release_branch}",
      ]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "${var.project}-github-plan"
  description          = "Assumed by GitHub Actions to plan Terraform and verify image signatures; read-only"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource-level permissions
  }

  statement {
    sid = "ReadImagesAndSignatures"
    actions = [
      "ecr:DescribeRepositories",
      "ecr:ListTagsForResource",
      "ecr:DescribeImages",
      "ecr:ListImages",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.api.arn]
  }

  statement {
    sid       = "ListAvailabilityZones"
    actions   = ["ec2:DescribeAvailabilityZones"]
    resources = ["*"] # this action does not support resource-level permissions
  }

  statement {
    sid       = "FindOidcProvider"
    actions   = ["iam:ListOpenIDConnectProviders"]
    resources = ["*"] # list actions do not support resource-level permissions
  }

  statement {
    sid       = "ReadOidcProvider"
    actions   = ["iam:GetOpenIDConnectProvider"]
    resources = [local.github_oidc_provider_arn]
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "plan-read-only"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}

# ---------- Migration role assumed by GitHub Actions (F-8) ----------
# The "Migrate database" workflow runs the one-off migration task through this
# role. It can start that task definition in that cluster, pass that task's
# execution role and nothing else: no other task definitions, no secrets, no
# Terraform state. Only jobs in the GitHub environment named below can assume
# it; that environment requires a reviewer's approval and allows main only, so
# what runs is the workflow as merged after review.
#
# What it does not stop: a run-task call through this role may still override
# the container command (ECS offers no IAM condition on overrides). The workflow
# is the only holder of the role and passes no override; changing it needs a
# reviewed pull request. Human administrators are outside this control.
# The v2 environment subject excludes historical guardless workflow runs. Set
# up its main-only approval protection before applying this role trust change.

locals {
  env_name                = "${var.project}-${var.environment}"
  migrate_task_definition = "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:task-definition/${local.env_name}-migrate:*"
  env_cluster_arn         = "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${local.env_name}"
}

data "aws_iam_policy_document" "migrate_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # A job that names a GitHub environment gets that environment, not the
    # branch, in its subject. Which branches may use it is enforced by the
    # environment's deployment branch policy.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_subject_prefix}:environment:${var.migrate_github_environment}"]
    }
  }
}

resource "aws_iam_role" "migrate" {
  name                 = "${var.project}-github-migrate"
  description          = "Assumed by the GitHub migration workflow to run the one-off migration task in ${local.env_name}"
  assume_role_policy   = data.aws_iam_policy_document.migrate_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "migrate" {
  statement {
    sid       = "RunMigrationTask"
    actions   = ["ecs:RunTask"]
    resources = [local.migrate_task_definition]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [local.env_cluster_arn]
    }
  }

  statement {
    sid       = "PassMigrationExecutionRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.env_name}-migrate-execution"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid       = "WatchMigrationTask"
    actions   = ["ecs:DescribeTasks"]
    resources = ["arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:task/${local.env_name}/*"]
  }

  statement {
    sid       = "ReadMigrationNetwork"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/${var.environment}/migrate/network"]
  }

  statement {
    sid       = "ReadMigrationLogs"
    actions   = ["logs:FilterLogEvents"]
    resources = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/${var.project}/${var.environment}/api:*"]
  }
}

resource "aws_iam_role_policy" "migrate" {
  name   = "run-migration"
  role   = aws_iam_role.migrate.id
  policy = data.aws_iam_policy_document.migrate.json
}
