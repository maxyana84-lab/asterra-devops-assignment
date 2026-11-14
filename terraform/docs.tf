# The half-pager, served from a public S3 bucket (assignment IV.3).
# This is the one deliberately public bucket: it holds a single static page.

resource "aws_s3_bucket" "docs" {
  bucket        = "${var.project}-docs-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  force_destroy = true

  tags = { Name = "${var.project}-docs" }
}

resource "aws_s3_bucket_public_access_block" "docs" {
  bucket = aws_s3_bucket.docs.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false # a public-read bucket policy is the point of this bucket
  restrict_public_buckets = false
}

data "aws_iam_policy_document" "docs_public_read" {
  statement {
    sid       = "PublicRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.docs.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "docs" {
  bucket = aws_s3_bucket.docs.id
  policy = data.aws_iam_policy_document.docs_public_read.json

  depends_on = [aws_s3_bucket_public_access_block.docs]
}

resource "aws_s3_object" "half_pager" {
  bucket        = aws_s3_bucket.docs.id
  key           = "index.html"
  source        = "${path.module}/../docs/index.html"
  etag          = filemd5("${path.module}/../docs/index.html")
  content_type  = "text/html; charset=utf-8"
  cache_control = "no-cache"

  depends_on = [aws_s3_bucket_policy.docs]
}
