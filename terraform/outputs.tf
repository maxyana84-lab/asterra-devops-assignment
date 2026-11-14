output "region" {
  value = var.aws_region
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "ingest_bucket" {
  description = "Upload *.geojson files here to load them."
  value       = aws_s3_bucket.ingest.bucket
}

output "geoloader_repository_url" {
  value = aws_ecr_repository.geoloader.repository_url
}

output "geoloader_function" {
  value = aws_lambda_function.geoloader.function_name
}

output "geoloader_log_group" {
  value = aws_cloudwatch_log_group.geoloader.name
}

output "geoloader_version" {
  value = var.geoloader_image_tag
}

output "geoloader_repository_name" {
  value = aws_ecr_repository.geoloader.name
}

output "github_release_role_arn" {
  description = "Role the GitHub Actions release pipeline assumes."
  value       = aws_iam_role.github_release.arn
}

output "db_endpoint" {
  description = "Private address of the database (resolves only inside the VPC)."
  value       = aws_db_instance.main.address
}

output "db_port" {
  value = aws_db_instance.main.port
}

output "db_name" {
  value = aws_db_instance.main.db_name
}

output "db_secret_arn" {
  description = "Secrets Manager secret holding the master username and password."
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}
