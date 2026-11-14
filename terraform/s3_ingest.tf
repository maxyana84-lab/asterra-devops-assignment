data "aws_caller_identity" "current" {}

# Private bucket where GeoJSON files land. S3 names are global, so the account
# and region are part of the name; this also lets two regions coexist.
resource "aws_s3_bucket" "ingest" {
  bucket        = "${var.project}-ingest-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  force_destroy = var.ingest_bucket_force_destroy

  tags = { Name = "${var.project}-ingest" }
}

resource "aws_s3_bucket_public_access_block" "ingest" {
  bucket = aws_s3_bucket.ingest.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ingest" {
  bucket = aws_s3_bucket.ingest.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "ingest" {
  bucket = aws_s3_bucket.ingest.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Refuse any request that does not use TLS.
resource "aws_s3_bucket_policy" "ingest" {
  bucket = aws_s3_bucket.ingest.id
  policy = data.aws_iam_policy_document.ingest_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.ingest]
}

data "aws_iam_policy_document" "ingest_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.ingest.arn, "${aws_s3_bucket.ingest.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# Every new *.geojson object triggers the loader.
resource "aws_s3_bucket_notification" "ingest" {
  bucket = aws_s3_bucket.ingest.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.geoloader.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = var.ingest_file_suffix
  }

  depends_on = [aws_lambda_permission.s3_invoke_geoloader]
}
