# A launch template completely describes a disposable application instance.
# Changing its image, container digest, port, or bootstrap instructions creates
# a new template version and triggers a rolling instance replacement.
resource "aws_launch_template" "application" {
  name_prefix            = "${local.name}-"
  image_id               = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  update_default_version = true

  vpc_security_group_ids = [aws_security_group.application.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.application.arn
  }

  # Requiring IMDSv2 makes common server-side request-forgery attacks less able
  # to obtain the instance role's temporary credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      delete_on_termination = true
      encrypted             = true
      volume_size           = var.root_volume_size_gib
      volume_type           = "gp3"
    }
  }

  dynamic "instance_market_options" {
    for_each = var.use_spot_instances ? [1] : []

    content {
      market_type = "spot"

      spot_options {
        spot_instance_type = "one-time"
      }
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    aws_region          = jsonencode(var.aws_region)
    bootstrap_log_group = jsonencode(aws_cloudwatch_log_group.bootstrap.name)
    container_image     = jsonencode(var.container_image)
    container_port      = var.container_port
    error_log_group     = jsonencode(aws_cloudwatch_log_group.errors.name)
    health_check_path   = jsonencode(var.health_check_path)
    application_group   = jsonencode(aws_cloudwatch_log_group.application.name)
  }))

  tag_specifications {
    resource_type = "instance"

    tags = merge(local.common_tags, {
      Name = "${local.name}-application"
    })
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge(local.common_tags, {
      Name = "${local.name}-root"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Auto Scaling owns the instances and replaces unhealthy or outdated members.
# Public IP assignment supplies inexpensive outbound internet access; there is
# still no direct inbound rule to these addresses.
resource "aws_autoscaling_group" "application" {
  name_prefix = "${local.name}-"

  min_size         = var.minimum_instances
  desired_capacity = var.desired_instances
  max_size         = var.maximum_instances

  vpc_zone_identifier       = aws_subnet.public[*].id
  target_group_arns         = [aws_lb_target_group.application.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  capacity_rebalance = var.use_spot_instances

  launch_template {
    id      = aws_launch_template.application.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = var.minimum_instances == 1 ? 0 : 50
      instance_warmup        = 180
    }

    triggers = ["tag"]
  }

  dynamic "tag" {
    for_each = merge(local.common_tags, { Name = "${local.name}-application" })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_lb_listener.http]
}

# Target tracking uses AWS-managed CloudWatch alarms and never grows past the
# explicit maximum_instances cost boundary.
resource "aws_autoscaling_policy" "cpu_target" {
  name                   = "${local.name}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.application.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    target_value = var.target_cpu_utilization

    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
  }
}
