# The ALB security group is the only public entrance. HTTPS should replace HTTP
# when a real domain and ACM certificate are available; this stub starts on HTTP
# so it does not pretend to own a domain it has not been given.
resource "aws_security_group" "alb" {
  name_prefix = "${local.name}-alb-"
  description = "Public HTTP entry for ${local.name}"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name}-alb"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.allowed_ipv4_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "Operator-approved HTTP source ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "alb_to_application" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward requests only to application instances"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.application.id
}

# Instances accept application traffic only from the ALB. There is intentionally
# no port 22 rule; Systems Manager provides authenticated administrative access.
resource "aws_security_group" "application" {
  name_prefix = "${local.name}-app-"
  description = "Private application traffic for ${local.name}"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name}-application"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "application_from_alb" {
  security_group_id            = aws_security_group.application.id
  description                  = "Accept only requests forwarded by the ALB"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.alb.id
}

# Outbound internet access is needed for operating-system updates, container
# pulls, Systems Manager, ECR, and CloudWatch Logs. Inbound replies are allowed
# automatically because security groups are stateful.
resource "aws_vpc_security_group_egress_rule" "application_ipv4" {
  security_group_id = aws_security_group.application.id
  description       = "TLS, updates, registry pulls, and AWS management APIs"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
