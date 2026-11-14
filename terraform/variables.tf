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

variable "github_oidc_subject_prefix" {
  description = <<-EOT
    How GitHub identifies the repository in its OIDC tokens. Set by scripts/deploy.sh,
    which asks GitHub: it is "repo:owner/name" for older repositories and
    "repo:owner@<id>/name@<id>" for repositories with immutable subjects.
  EOT
  type        = string

  validation {
    condition     = can(regex("^repo:[^/:]+/[^/:]+$", var.github_oidc_subject_prefix))
    error_message = "Use the form repo:owner/name or repo:owner@id/name@id."
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

variable "interface_endpoints" {
  description = "AWS services the private subnets reach through interface endpoints (there is no NAT gateway)."
  type        = list(string)
  default     = ["secretsmanager", "ecr.api", "ecr.dkr", "logs"]
}

# ---------- Public access ----------

variable "public_ingress_cidrs" {
  description = "Address ranges allowed to reach the public MapServer."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "public_port" {
  description = "Port the public MapServer is served on."
  type        = number
  default     = 80
}

# ---------- Container services (ECS Fargate) ----------

variable "service_image_tags" {
  description = "Image tag of each service. Set by scripts/deploy.sh from services/<name>/VERSION."
  type        = map(string)

  validation {
    condition     = toset(keys(var.service_image_tags)) == toset(["gdal", "mapserver"])
    error_message = "Provide a tag for exactly these services: gdal, mapserver."
  }
}

variable "service_container_port" {
  description = "Port both service containers listen on."
  type        = number
  default     = 8080
}

variable "mapserver_cpu" {
  description = "CPU units of one MapServer task (1024 = 1 vCPU)."
  type        = number
  default     = 256
}

variable "mapserver_memory_mb" {
  description = "Memory of one MapServer task."
  type        = number
  default     = 512
}

variable "mapserver_min_tasks" {
  description = "MapServer tasks running when traffic is low."
  type        = number
  default     = 1
}

variable "mapserver_max_tasks" {
  description = "Upper limit for MapServer autoscaling."
  type        = number
  default     = 3
}

variable "mapserver_requests_per_task_per_minute" {
  description = "Autoscaling threshold: above this many requests per task per minute, another task is started."
  type        = number
  default     = 300
}

variable "gdal_cpu" {
  description = "CPU units of the GDAL task (1024 = 1 vCPU)."
  type        = number
  default     = 512
}

variable "gdal_memory_mb" {
  description = "Memory of the GDAL task. Documents are processed in memory."
  type        = number
  default     = 1024
}

variable "gdal_task_count" {
  description = "Number of GDAL tasks."
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
