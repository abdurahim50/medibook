# The image repository lives in the bootstrap stack (infra/bootstrap), because it
# must survive the per-session destroy of this environment: CI publishes signed
# images to it at any time.
data "aws_ecr_repository" "api" {
  name = "${var.project}/api"
}
