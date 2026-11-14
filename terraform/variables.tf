variable "aws_region" {
  description = "AWS region to deploy into. Set by scripts/deploy.sh."
  type        = string
}

variable "project" {
  description = "Prefix for resource names and the Project tag."
  type        = string
  default     = "asterra"
}

# ---------- CI/CD ----------

variable "github_repository" {
  description = "GitHub repository (owner/name) whose release pipeline may deploy. Set by scripts/deploy.sh from the git remote."
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "Use the form owner/name."
  }
}

variable "github_release_branch" {
  description = "Only workflows running on this branch may deploy."
  type        = string
  default     = "main"
}

# ---------- Network ----------

variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread subnets over. RDS needs at least 2."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "An RDS subnet group needs subnets in at least 2 availability zones."
  }
}

variable "endpoint_az_count" {
  description = "Number of private subnets that get a network interface for each interface endpoint."
  type        = number
  default     = 1
}

# ---------- Ingest bucket ----------

variable "ingest_file_suffix" {
  description = "Only objects whose key ends with this suffix trigger the loader."
  type        = string
  default     = ".geojson"
}

variable "ingest_bucket_force_destroy" {
  description = "Allow destroying the ingest bucket while it still holds files. Keep true for a throwaway environment."
  type        = bool
  default     = true
}

# ---------- GeoJSON loader (Lambda) ----------

variable "geoloader_image_tag" {
  description = "Tag of the loader image in ECR. Set by scripts/deploy.sh from app/VERSION."
  type        = string
}

variable "geoloader_timeout_seconds" {
  description = "Maximum run time of one loader invocation."
  type        = number
  default     = 120
}

variable "geoloader_memory_mb" {
  description = "Memory of the loader. The file is parsed in memory, so this bounds the file size."
  type        = number
  default     = 512
}

variable "geoloader_max_file_mb" {
  description = "Files larger than this are rejected without being downloaded."
  type        = number
  default     = 50
}

variable "log_retention_days" {
  description = "Days to keep CloudWatch logs."
  type        = number
  default     = 14
}

variable "ecr_images_to_keep" {
  description = "Number of most recent images kept in each ECR repository."
  type        = number
  default     = 10
}

variable "ecr_force_delete" {
  description = "Allow destroying ECR repositories that still hold images. Keep true for a throwaway environment."
  type        = bool
  default     = true
}

# ---------- Database ----------

variable "db_name" {
  description = "Name of the initial database."
  type        = string
  default     = "geodata"
}

variable "db_username" {
  description = "Master username. The password is generated and kept by RDS in Secrets Manager."
  type        = string
  default     = "geoadmin"
}

variable "db_engine_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "17"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Database storage in GiB."
  type        = number
  default     = 20
}

variable "db_backup_retention_days" {
  description = "Days to keep automated backups."
  type        = number
  default     = 1
}

variable "db_deletion_protection" {
  description = "Protect the database from deletion. Keep false for a throwaway environment."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Keep true for a throwaway environment."
  type        = bool
  default     = true
}
