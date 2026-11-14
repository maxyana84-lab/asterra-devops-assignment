locals {
  geoloader_name = "${var.project}-geoloader"
}

# The image is built and pushed by scripts/deploy.sh (or the CI pipeline) before
# this is read. Pinning the digest makes Lambda pick up exactly that image.
data "aws_ecr_image" "geoloader" {
  repository_name = aws_ecr_repository.geoloader.name
  image_tag       = var.geoloader_image_tag
}

# ---------- IAM: what the loader is allowed to do ----------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "geoloader" {
  name               = "${local.geoloader_name}-${var.aws_region}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "geoloader" {
  statement {
    sid       = "ReadIngestedFiles"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.ingest.arn}/*"]
  }

  statement {
    sid       = "ReadDatabaseCredentials"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.main.master_user_secret[0].secret_arn]
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.geoloader.arn}:*"]
  }

  # A Lambda inside a VPC needs to manage its own network interfaces.
  # These EC2 actions do not support resource-level restrictions.
  statement {
    sid = "ManageVpcNetworkInterfaces"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "geoloader" {
  name   = "geoloader"
  role   = aws_iam_role.geoloader.id
  policy = data.aws_iam_policy_document.geoloader.json
}

# ---------- Network: the loader may talk only to the DB, Secrets Manager and S3 ----------

resource "aws_security_group" "geoloader" {
  name        = local.geoloader_name
  description = "GeoJSON loader Lambda"
  vpc_id      = aws_vpc.main.id

  tags = { Name = local.geoloader_name }
}

resource "aws_vpc_security_group_egress_rule" "geoloader_to_db" {
  security_group_id            = aws_security_group.geoloader.id
  description                  = "PostgreSQL to the database"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "geoloader_to_endpoints" {
  security_group_id            = aws_security_group.geoloader.id
  description                  = "HTTPS to the Secrets Manager endpoint"
  referenced_security_group_id = aws_security_group.endpoints.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "geoloader_to_s3" {
  security_group_id = aws_security_group.geoloader.id
  description       = "HTTPS to S3 through the gateway endpoint"
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "geoloader_to_gdal" {
  security_group_id            = aws_security_group.geoloader.id
  description                  = "HTTP to the private GDAL service"
  referenced_security_group_id = aws_security_group.service["gdal"].id
  ip_protocol                  = "tcp"
  from_port                    = var.service_container_port
  to_port                      = var.service_container_port
}

# ---------- The function ----------

resource "aws_cloudwatch_log_group" "geoloader" {
  name              = "/aws/lambda/${local.geoloader_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "geoloader" {
  function_name = local.geoloader_name
  role          = aws_iam_role.geoloader.arn

  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.geoloader.repository_url}@${data.aws_ecr_image.geoloader.image_digest}"
  architectures = ["x86_64"]

  timeout     = var.geoloader_timeout_seconds
  memory_size = var.geoloader_memory_mb

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.geoloader.id]
  }

  environment {
    variables = {
      DB_HOST        = aws_db_instance.main.address
      DB_PORT        = tostring(aws_db_instance.main.port)
      DB_NAME        = aws_db_instance.main.db_name
      DB_SECRET_ARN  = aws_db_instance.main.master_user_secret[0].secret_arn
      MAX_FILE_BYTES = tostring(var.geoloader_max_file_mb * 1024 * 1024)
      # The private GDAL service computes area and length of each loaded file.
      GDAL_SERVICE_URL = local.gdal_service_url
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.geoloader.name
  }

  tags = { Name = local.geoloader_name, Version = var.geoloader_image_tag }

  depends_on = [aws_iam_role_policy.geoloader, aws_vpc_endpoint.interface]
}

resource "aws_lambda_permission" "s3_invoke_geoloader" {
  statement_id   = "AllowIngestBucket"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.geoloader.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.ingest.arn
  source_account = data.aws_caller_identity.current.account_id
}

# Enable PostGIS and create the table. The database is private, so this runs
# inside the VPC, through the loader itself. Re-runs whenever the image changes.
resource "aws_lambda_invocation" "init_db" {
  function_name = aws_lambda_function.geoloader.function_name
  input         = jsonencode({ action = "init_db" })

  triggers = {
    image = data.aws_ecr_image.geoloader.image_digest
  }
}
