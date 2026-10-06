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
