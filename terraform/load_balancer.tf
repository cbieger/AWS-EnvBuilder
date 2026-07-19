# The ALB presents one stable URL while the instances behind it are routinely
# replaced. Access logging is mandatory for this workspace.
resource "aws_lb" "application" {
  name               = substr("${local.name}-alb", 0, 32)
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]
}

# The target group checks a documented, unauthenticated application endpoint.
# A replacement instance receives traffic only after returning HTTP 200-399.
resource "aws_lb_target_group" "application" {
  name_prefix = substr("${local.name}-", 0, 6)
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.this.id

  deregistration_delay = 30

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200-399"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# HTTP is suitable only for an initial development stub with no secrets. Add an
# ACM certificate and HTTPS listener before transmitting credentials or private
# data through this endpoint.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.application.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.application.arn
  }
}
