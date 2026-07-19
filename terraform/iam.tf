# EC2 assumes this role; human deployment credentials are never copied onto an
# instance. The trust policy grants only the EC2 service permission to assume it.
data "aws_iam_policy_document" "instance_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name_prefix        = "${local.name}-instance-"
  assume_role_policy = data.aws_iam_policy_document.instance_trust.json

  lifecycle {
    create_before_destroy = true
  }
}

# AWS maintains the exact permissions needed for Session Manager. This enables
# console/CLI shell access without opening SSH to the internet.
resource "aws_iam_role_policy_attachment" "systems_manager" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Application instances may emit logs and pull only from their own private ECR
# repository. Authorization-token retrieval must use '*' by AWS API design.
data "aws_iam_policy_document" "instance_runtime" {
  statement {
    sid    = "WriteWorkspaceLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents"
    ]
    resources = [
      "${aws_cloudwatch_log_group.application.arn}:*",
      "${aws_cloudwatch_log_group.bootstrap.arn}:*",
      "${aws_cloudwatch_log_group.errors.arn}:*"
    ]
  }

  statement {
    sid       = "ObtainEcrLoginToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PullWorkspaceImage"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer"
    ]
    resources = [aws_ecr_repository.application.arn]
  }
}

resource "aws_iam_role_policy" "instance_runtime" {
  name   = "workspace-runtime"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_runtime.json
}

resource "aws_iam_instance_profile" "application" {
  name_prefix = "${local.name}-"
  role        = aws_iam_role.instance.name

  lifecycle {
    create_before_destroy = true
  }
}
