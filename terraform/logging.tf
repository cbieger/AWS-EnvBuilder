# CloudWatch deletes routine output sooner than error-specific output. This
# preserves diagnostic evidence while placing a ceiling on ongoing storage cost.
resource "aws_cloudwatch_log_group" "application" {
  name              = "/${local.name}/application"
  retention_in_days = var.routine_log_retention_days
}

resource "aws_cloudwatch_log_group" "bootstrap" {
  name              = "/${local.name}/bootstrap"
  retention_in_days = var.routine_log_retention_days
}

resource "aws_cloudwatch_log_group" "errors" {
  name              = "/${local.name}/errors"
  retention_in_days = var.error_log_retention_days
}

# ALB request logs are stored in a private, encrypted S3 bucket. The account ID
# makes the globally unique bucket name deterministic for this workspace.
resource "aws_s3_bucket" "alb_logs" {
  # substr protects S3's 63-character limit when project/environment use their
  # maximum lengths. Account and Region remain in the retained unique portion.
  bucket        = substr("${local.name}-${data.aws_caller_identity.current.account_id}-${var.aws_region}-alb-logs", 0, 63)
  force_destroy = true

  tags = {
    Name    = "${local.name}-alb-logs"
    Purpose = "load-balancer-access-logs"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-old-request-logs"
    status = "Enabled"

    filter {
      prefix = "alb/"
    }

    expiration {
      days = var.alb_access_log_retention_days
    }
  }
}

# Only AWS's regional load-balancer log delivery service may write beneath the
# account-specific key prefix. Public reads remain blocked.
data "aws_iam_policy_document" "alb_log_delivery" {
  statement {
    sid     = "AllowRegionalLoadBalancerLogDelivery"
    effect  = "Allow"
    actions = ["s3:PutObject"]

    resources = [
      "${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    ]

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:${data.aws_partition.current.partition}:elasticloadbalancing:${var.aws_region}:${data.aws_caller_identity.current.account_id}:loadbalancer/*"
      ]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = data.aws_iam_policy_document.alb_log_delivery.json
}
