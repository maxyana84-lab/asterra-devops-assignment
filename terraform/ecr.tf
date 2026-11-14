resource "aws_ecr_repository" "geoloader" {
  name = "${var.project}-geoloader"
  # Tags are version numbers and are never overwritten: a version is one image.
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.ecr_force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = { Name = "${var.project}-geoloader" }
}

resource "aws_ecr_lifecycle_policy" "geoloader" {
  repository = aws_ecr_repository.geoloader.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.ecr_images_to_keep
      }
      action = { type = "expire" }
    }]
  })
}
