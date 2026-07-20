# Optional AWS-hosted, cancellable scheduled teardown. Nothing in this file is
# created unless the operator explicitly enables scheduling during plan/apply.
# The protected S3 backend and bootstrap IAM user remain outside Terraform and
# therefore survive this runtime-only self-destruct.

locals {
  scheduled_destroy_count = var.scheduled_destroy_enabled ? 1 : 0
  scheduled_destroy_name = substr(
    "${local.name}-destroy-${substr(var.scheduled_destroy_configuration.schedule_id, 0, 8)}",
    0,
    50
  )
}

resource "aws_dynamodb_table" "scheduled_destroy" {
  count = local.scheduled_destroy_count

  name         = local.scheduled_destroy_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ScheduleId"

  attribute {
    name = "ScheduleId"
    type = "S"
  }

  # Lambda creates and conditionally changes the single mutable schedule item.
  # Terraform intentionally does not own that item, which prevents a later plan
  # from silently changing CANCELLED back to ACTIVE or PENDING.
  deletion_protection_enabled = false
}

resource "aws_sns_topic" "scheduled_destroy_email" {
  count = local.scheduled_destroy_count
  name  = "${local.scheduled_destroy_name}-email"
}

resource "aws_sns_topic_subscription" "scheduled_destroy_email" {
  count = local.scheduled_destroy_count

  topic_arn = aws_sns_topic.scheduled_destroy_email[0].arn
  protocol  = "email"
  endpoint  = var.scheduled_destroy_contacts.operator_email
}

resource "aws_cloudwatch_log_group" "scheduled_destroy_controller" {
  count = local.scheduled_destroy_count

  name              = "/aws/lambda/${local.scheduled_destroy_name}"
  retention_in_days = 90
}

resource "aws_cloudwatch_log_group" "scheduled_destroy_build" {
  count = local.scheduled_destroy_count

  name              = "/aws/codebuild/${local.scheduled_destroy_name}"
  retention_in_days = 90
}

resource "aws_iam_role" "scheduled_destroy_controller" {
  count = local.scheduled_destroy_count
  name  = "${local.scheduled_destroy_name}-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role" "scheduled_destroy_build" {
  count = local.scheduled_destroy_count
  name  = "${local.scheduled_destroy_name}-build"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "codebuild.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role" "scheduled_destroy_scheduler" {
  count = local.scheduled_destroy_count
  name  = "${local.scheduled_destroy_name}-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "scheduler.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduled_destroy_build" {
  count = local.scheduled_destroy_count
  name  = "scheduled-runtime-destroy"
  role  = aws_iam_role.scheduled_destroy_build[0].id

  # The ephemeral build must read and destroy every resource Terraform manages.
  # This list comes from the same audited source used by deployer preflight. The
  # role is deleted by its own successful Terraform destroy run.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ScheduledTerraformDestroy"
      Effect   = "Allow"
      Action   = var.scheduled_destroy_configuration.runner_actions
      Resource = "*"
    }]
  })
}

resource "aws_codebuild_project" "scheduled_destroy" {
  count = local.scheduled_destroy_count

  name          = local.scheduled_destroy_name
  description   = "Deletion-only Terraform runner for an operator-approved deadline."
  service_role  = aws_iam_role.scheduled_destroy_build[0].arn
  build_timeout = 60

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "EXPECTED_ACCOUNT"
      value = data.aws_caller_identity.current.account_id
    }
    environment_variable {
      name  = "BACKEND_BUCKET"
      value = var.scheduled_destroy_configuration.source_bucket
    }
    environment_variable {
      name  = "BACKEND_KEY"
      value = var.scheduled_destroy_configuration.backend_key
    }
    environment_variable {
      name  = "BACKEND_REGION"
      value = var.scheduled_destroy_configuration.backend_region
    }
    environment_variable {
      name  = "SCHEDULE_TABLE"
      value = aws_dynamodb_table.scheduled_destroy[0].name
    }
    environment_variable {
      name  = "SCHEDULE_ID"
      value = var.scheduled_destroy_configuration.schedule_id
    }
    environment_variable {
      name  = "PROJECT_NAME"
      value = var.project_name
    }
    environment_variable {
      name  = "ENVIRONMENT_NAME"
      value = var.environment
    }
    environment_variable {
      name  = "TF_VAR_budget_alert_emails"
      value = jsonencode(var.budget_alert_emails)
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.scheduled_destroy_build[0].name
      stream_name = "terraform-destroy"
    }
  }

  source {
    type     = "S3"
    location = "${var.scheduled_destroy_configuration.source_bucket}/${var.scheduled_destroy_configuration.terraform_source_key}"

    # Every destructive boundary is rechecked inside AWS: account, schedule
    # state, deletion-only plan actions, and a final atomic execution claim.
    buildspec = <<-YAML
      version: 0.2
      phases:
        install:
          commands:
            - TERRAFORM_VERSION=1.15.8
            - curl -fsSLO "https://releases.hashicorp.com/terraform/$${TERRAFORM_VERSION}/terraform_$${TERRAFORM_VERSION}_linux_amd64.zip"
            - curl -fsSLO "https://releases.hashicorp.com/terraform/$${TERRAFORM_VERSION}/terraform_$${TERRAFORM_VERSION}_SHA256SUMS"
            - grep " terraform_$${TERRAFORM_VERSION}_linux_amd64.zip$" "terraform_$${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c -
            - unzip -o "terraform_$${TERRAFORM_VERSION}_linux_amd64.zip" -d /usr/local/bin
        pre_build:
          commands:
            - python3 scheduled_destroy_build.py verify-account --expected "$${EXPECTED_ACCOUNT}"
            - python3 scheduled_destroy_build.py check-status --table "$${SCHEDULE_TABLE}" --schedule-id "$${SCHEDULE_ID}" --expected TRIGGERED
            - python3 scheduled_destroy_build.py write-backend --bucket "$${BACKEND_BUCKET}" --key "$${BACKEND_KEY}" --region "$${BACKEND_REGION}" --output backend.hcl
            - terraform init -input=false -backend-config=backend.hcl
        build:
          commands:
            - terraform plan -destroy -input=false -out=scheduled-destroy.tfplan -var="aws_region=$${AWS_REGION}" -var="project_name=$${PROJECT_NAME}" -var="environment=$${ENVIRONMENT_NAME}"
            - terraform show -json scheduled-destroy.tfplan > scheduled-destroy.json
            - python3 scheduled_destroy_build.py validate-plan scheduled-destroy.json
            - python3 scheduled_destroy_build.py claim-execution --table "$${SCHEDULE_TABLE}" --schedule-id "$${SCHEDULE_ID}"
            - terraform apply -input=false scheduled-destroy.tfplan
    YAML
  }
}

resource "aws_iam_role_policy" "scheduled_destroy_controller" {
  count = local.scheduled_destroy_count
  name  = "scheduled-destroy-controller"
  role  = aws_iam_role.scheduled_destroy_controller[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ControllerLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.scheduled_destroy_controller[0].arn}:*"
      },
      {
        Sid      = "ScheduleState"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.scheduled_destroy[0].arn
      },
      {
        Sid      = "EmailConfirmationAndNotices"
        Effect   = "Allow"
        Action   = ["sns:ListSubscriptionsByTopic", "sns:Publish"]
        Resource = aws_sns_topic.scheduled_destroy_email[0].arn
      },
      {
        Sid      = "SmsNotices"
        Effect   = "Allow"
        Action   = "sms-voice:SendTextMessage"
        Resource = "*"
      },
      {
        Sid      = "StartDeletionOnlyBuild"
        Effect   = "Allow"
        Action   = "codebuild:StartBuild"
        Resource = aws_codebuild_project.scheduled_destroy[0].arn
      }
    ]
  })
}

resource "aws_lambda_function" "scheduled_destroy" {
  count = local.scheduled_destroy_count

  function_name    = local.scheduled_destroy_name
  description      = "Sends teardown notices, authenticates SMS CANCEL, and starts CodeBuild."
  role             = aws_iam_role.scheduled_destroy_controller[0].arn
  runtime          = "python3.12"
  handler          = "lambda_function.lambda_handler"
  timeout          = 60
  memory_size      = 128
  s3_bucket        = var.scheduled_destroy_configuration.source_bucket
  s3_key           = var.scheduled_destroy_configuration.controller_source_key
  source_code_hash = var.scheduled_destroy_configuration.controller_source_hash_base64

  environment {
    variables = {
      SCHEDULE_TABLE         = aws_dynamodb_table.scheduled_destroy[0].name
      SCHEDULE_ID            = var.scheduled_destroy_configuration.schedule_id
      DEADLINE_EPOCH         = tostring(var.scheduled_destroy_configuration.deadline_epoch)
      DEADLINE_UTC           = var.scheduled_destroy_configuration.deadline_utc
      LOCAL_DEADLINE         = var.scheduled_destroy_configuration.local_deadline
      OPERATOR_PHONE         = var.scheduled_destroy_contacts.operator_phone
      OPERATOR_EMAIL         = var.scheduled_destroy_contacts.operator_email
      SMS_ORIGINATION_NUMBER = var.scheduled_destroy_configuration.sms_origination_number
      EMAIL_TOPIC_ARN        = aws_sns_topic.scheduled_destroy_email[0].arn
      CODEBUILD_PROJECT      = aws_codebuild_project.scheduled_destroy[0].name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.scheduled_destroy_controller,
    aws_iam_role_policy.scheduled_destroy_controller,
  ]
}

resource "aws_lambda_permission" "scheduled_destroy_sms" {
  count = local.scheduled_destroy_count

  statement_id  = "AllowInboundTwoWaySms"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scheduled_destroy[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.scheduled_destroy_configuration.sms_inbound_topic_arn
}

resource "aws_sns_topic_subscription" "scheduled_destroy_sms" {
  count = local.scheduled_destroy_count

  topic_arn = var.scheduled_destroy_configuration.sms_inbound_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.scheduled_destroy[0].arn

  depends_on = [aws_lambda_permission.scheduled_destroy_sms]
}

resource "aws_iam_role_policy" "scheduled_destroy_scheduler" {
  count = local.scheduled_destroy_count
  name  = "invoke-scheduled-destroy-controller"
  role  = aws_iam_role.scheduled_destroy_scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.scheduled_destroy[0].arn
    }]
  })
}

resource "aws_scheduler_schedule" "scheduled_destroy" {
  count = local.scheduled_destroy_count

  name                = local.scheduled_destroy_name
  description         = "Checks required warning milestones and the approved UTC teardown deadline."
  schedule_expression = "rate(1 minute)"
  state               = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.scheduled_destroy[0].arn
    role_arn = aws_iam_role.scheduled_destroy_scheduler[0].arn

    retry_policy {
      maximum_event_age_in_seconds = 60
      maximum_retry_attempts       = 2
    }
  }
}
