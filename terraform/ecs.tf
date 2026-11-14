# The two long-running containers run on ECS Fargate, in the private subnets:
#   mapserver - public WMS server, reached only through the load balancers
#   gdal      - private GDAL + GeoPandas microservice, reachable only inside the VPC

locals {
  services = {
    mapserver = { cpu = var.mapserver_cpu, memory = var.mapserver_memory_mb }
    gdal      = { cpu = var.gdal_cpu, memory = var.gdal_memory_mb }
  }

  gdal_dns_name    = "gdal.${aws_service_discovery_private_dns_namespace.internal.name}"
  gdal_service_url = "http://${local.gdal_dns_name}:${var.service_container_port}"

  # Used by both load balancers to decide whether MapServer is healthy.
  mapserver_health_path = "/?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetCapabilities"
}

data "aws_ecr_image" "service" {
  for_each = var.service_image_tags

  repository_name = aws_ecr_repository.service[each.key].name
  image_tag       = each.value
}

resource "aws_ecs_cluster" "main" {
  name = var.project

  tags = { Name = var.project }
}

resource "aws_cloudwatch_log_group" "service" {
  for_each = local.services

  name              = "/ecs/${var.project}-${each.key}"
  retention_in_days = var.log_retention_days
}

# ---------- IAM ----------

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: what ECS itself needs to start a task (pull the image, write logs).
resource "aws_iam_role" "ecs_execution" {
  name               = "${var.project}-ecs-execution-${var.aws_region}"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "ecs_execution" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource-level restrictions
  }

  statement {
    sid       = "PullServiceImages"
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [for repo in aws_ecr_repository.service : repo.arn]
  }

  statement {
    sid       = "WriteServiceLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [for group in aws_cloudwatch_log_group.service : "${group.arn}:*"]
  }
}

resource "aws_iam_role_policy" "ecs_execution" {
  name   = "execution"
  role   = aws_iam_role.ecs_execution.id
  policy = data.aws_iam_policy_document.ecs_execution.json
}

# Task role: what the application code may do in AWS. Neither service calls
# any AWS API, so the role deliberately has no permissions.
resource "aws_iam_role" "ecs_task" {
  name               = "${var.project}-ecs-task-${var.aws_region}"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# ---------- Security groups ----------

resource "aws_security_group" "service" {
  for_each = local.services

  name        = "${var.project}-${each.key}"
  description = "${each.key} tasks"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-${each.key}" }
}

# Tasks start no connections except to pull their image and ship logs.
resource "aws_vpc_security_group_egress_rule" "service_to_endpoints" {
  for_each = local.services

  security_group_id            = aws_security_group.service[each.key].id
  description                  = "HTTPS to the ECR and CloudWatch Logs endpoints"
  referenced_security_group_id = aws_security_group.endpoints.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "service_to_s3" {
  for_each = local.services

  security_group_id = aws_security_group.service[each.key].id
  description       = "HTTPS to S3 (image layers) through the gateway endpoint"
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# MapServer accepts traffic only from the application load balancer.
resource "aws_vpc_security_group_ingress_rule" "mapserver_from_alb" {
  security_group_id            = aws_security_group.service["mapserver"].id
  description                  = "HTTP from the application load balancer"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.service_container_port
  to_port                      = var.service_container_port
}

# The GDAL service is private: reachable from anything inside the VPC, nothing outside.
resource "aws_vpc_security_group_ingress_rule" "gdal_from_vpc" {
  security_group_id = aws_security_group.service["gdal"].id
  description       = "HTTP from the VPC"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = var.service_container_port
  to_port           = var.service_container_port
}

# ---------- Private DNS name for the GDAL service ----------

resource "aws_service_discovery_private_dns_namespace" "internal" {
  name        = "${var.project}.internal"
  description = "Private names of services in the ${var.project} VPC"
  vpc         = aws_vpc.main.id
}

resource "aws_service_discovery_service" "gdal" {
  name = "gdal"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.internal.id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 10
    }
  }
}

# ---------- Task definitions ----------

resource "aws_ecs_task_definition" "service" {
  for_each = local.services

  family                   = "${var.project}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = each.key
    image     = "${aws_ecr_repository.service[each.key].repository_url}@${data.aws_ecr_image.service[each.key].image_digest}"
    essential = true

    portMappings = [{ containerPort = var.service_container_port, protocol = "tcp" }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.service[each.key].name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = each.key
      }
    }
  }])

  tags = { Name = "${var.project}-${each.key}", Version = var.service_image_tags[each.key] }
}

# ---------- Services ----------

resource "aws_ecs_service" "gdal" {
  name            = "gdal"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.service["gdal"].arn
  desired_count   = var.gdal_task_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.service["gdal"].id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.gdal.arn
  }

  # A deployment whose tasks cannot start is rolled back instead of retried forever,
  # and terraform apply waits until the service is really running.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  wait_for_steady_state = true

  depends_on = [aws_vpc_endpoint.interface, aws_iam_role_policy.ecs_execution]
}

resource "aws_ecs_service" "mapserver" {
  name            = "mapserver"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.service["mapserver"].arn
  desired_count   = var.mapserver_min_tasks
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.service["mapserver"].id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.mapserver.arn
    container_name   = "mapserver"
    container_port   = var.service_container_port
  }
  health_check_grace_period_seconds = 60

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  wait_for_steady_state = true

  lifecycle {
    # The number of tasks is owned by autoscaling after creation.
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_lb_listener.alb_http,
    aws_vpc_endpoint.interface,
    aws_iam_role_policy.ecs_execution,
  ]
}

# ---------- Autoscaling of the public server ----------
# When requests per task per minute exceed the target, ECS adds a task behind
# the load balancer; when traffic falls, it removes it again.

resource "aws_appautoscaling_target" "mapserver" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.mapserver.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.mapserver_min_tasks
  max_capacity       = var.mapserver_max_tasks
}

resource "aws_appautoscaling_policy" "mapserver_requests" {
  name               = "${var.project}-mapserver-requests-per-minute"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.mapserver.service_namespace
  resource_id        = aws_appautoscaling_target.mapserver.resource_id
  scalable_dimension = aws_appautoscaling_target.mapserver.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.mapserver_requests_per_task_per_minute
    scale_out_cooldown = 60
    scale_in_cooldown  = 120

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.alb.arn_suffix}/${aws_lb_target_group.mapserver.arn_suffix}"
    }
  }
}
