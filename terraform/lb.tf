# Public entry point of MapServer:
#
#   internet -> NLB (Elastic IPs, public subnets) -> ALB (private subnets) -> tasks
#
# The network load balancer provides the static Elastic IPs the assignment asks
# for. The application load balancer behind it counts HTTP requests, which is
# what autoscaling reacts to. The public subnets contain nothing but the NLB.

resource "aws_eip" "public" {
  count = var.az_count

  domain = "vpc"

  tags = { Name = "${var.project}-public-${local.azs[count.index]}" }

  depends_on = [aws_internet_gateway.main]
}

# ---------- Security groups ----------

resource "aws_security_group" "nlb" {
  name        = "${var.project}-nlb"
  description = "Public entry point: the only group that accepts traffic from outside the VPC"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-nlb" }
}

resource "aws_vpc_security_group_ingress_rule" "nlb_from_public" {
  for_each = toset(var.public_ingress_cidrs)

  security_group_id = aws_security_group.nlb.id
  description       = "HTTP from allowed public addresses"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = var.public_port
  to_port           = var.public_port
}

resource "aws_vpc_security_group_egress_rule" "nlb_to_alb" {
  security_group_id            = aws_security_group.nlb.id
  description                  = "HTTP to the application load balancer"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.public_port
  to_port                      = var.public_port
}

resource "aws_security_group" "alb" {
  name        = "${var.project}-alb"
  description = "Internal application load balancer in front of MapServer"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_nlb" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP that came in through the network load balancer"
  referenced_security_group_id = aws_security_group.nlb.id
  ip_protocol                  = "tcp"
  from_port                    = var.public_port
  to_port                      = var.public_port
}

resource "aws_vpc_security_group_egress_rule" "alb_to_mapserver" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP to MapServer tasks"
  referenced_security_group_id = aws_security_group.service["mapserver"].id
  ip_protocol                  = "tcp"
  from_port                    = var.service_container_port
  to_port                      = var.service_container_port
}

# ---------- Application load balancer (internal) ----------

resource "aws_lb" "alb" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  internal           = true
  subnets            = aws_subnet.private[*].id
  security_groups    = [aws_security_group.alb.id]

  drop_invalid_header_fields = true

  tags = { Name = "${var.project}-alb" }
}

resource "aws_lb_target_group" "mapserver" {
  name                 = "${var.project}-mapserver"
  vpc_id               = aws_vpc.main.id
  target_type          = "ip"
  protocol             = "HTTP"
  port                 = var.service_container_port
  deregistration_delay = 30

  health_check {
    path                = local.mapserver_health_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.project}-mapserver" }
}

resource "aws_lb_listener" "alb_http" {
  load_balancer_arn = aws_lb.alb.arn
  protocol          = "HTTP"
  port              = var.public_port

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mapserver.arn
  }
}

# ---------- Network load balancer (public, Elastic IPs) ----------

resource "aws_lb" "nlb" {
  name               = "${var.project}-nlb"
  load_balancer_type = "network"
  internal           = false
  security_groups    = [aws_security_group.nlb.id]

  dynamic "subnet_mapping" {
    for_each = range(var.az_count)

    content {
      subnet_id     = aws_subnet.public[subnet_mapping.value].id
      allocation_id = aws_eip.public[subnet_mapping.value].id
    }
  }

  tags = { Name = "${var.project}-nlb" }
}

resource "aws_lb_target_group" "nlb_to_alb" {
  name        = "${var.project}-nlb-to-alb"
  vpc_id      = aws_vpc.main.id
  target_type = "alb"
  protocol    = "TCP"
  port        = var.public_port

  health_check {
    protocol            = "HTTP"
    path                = local.mapserver_health_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.project}-nlb-to-alb" }
}

resource "aws_lb_target_group_attachment" "nlb_to_alb" {
  target_group_arn = aws_lb_target_group.nlb_to_alb.arn
  target_id        = aws_lb.alb.arn
  port             = var.public_port

  # The ALB can be registered only once it has a listener on this port.
  depends_on = [aws_lb_listener.alb_http]
}

resource "aws_lb_listener" "nlb_tcp" {
  load_balancer_arn = aws_lb.nlb.arn
  protocol          = "TCP"
  port              = var.public_port

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_to_alb.arn
  }
}
