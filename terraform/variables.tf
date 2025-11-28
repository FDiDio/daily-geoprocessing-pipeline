# Terraform variables for Agricultural Monitoring Pipeline deployment

variable "namespace" {
  description = "Kubernetes namespace for Agricultural Monitoring Pipeline"
  type        = string
  default     = "agricultural-pipeline"
}

variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubernetes context to use"
  type        = string
  default     = "docker-desktop" # Change to "minikube" or "kind-kind" as needed
}

# PostgreSQL Configuration
variable "postgres_user" {
  description = "PostgreSQL username"
  type        = string
  default     = "dagster"
  sensitive   = true
}

variable "postgres_password" {
  description = "PostgreSQL password"
  type        = string
  default     = "dagster_secure_password" # Change in production!
  sensitive   = true
}

variable "postgres_db" {
  description = "PostgreSQL database name"
  type        = string
  default     = "dagster"
}

# MinIO Configuration
variable "minio_root_user" {
  description = "MinIO root user (access key)"
  type        = string
  default     = "minioadmin"
  sensitive   = true
}

variable "minio_root_password" {
  description = "MinIO root password (secret key)"
  type        = string
  default     = "minioadmin"
  sensitive   = true
}

# Dagster Configuration
variable "dagster_image" {
  description = "Docker image for Dagster (must include your code)"
  type        = string
  default     = "agricultural-pipeline:latest"
}

variable "dagster_image_pull_policy" {
  description = "Image pull policy for Dagster containers"
  type        = string
  default     = "IfNotPresent" # Use "Always" if pushing to remote registry
}

# Resource Configuration
variable "enable_persistent_storage" {
  description = "Enable persistent storage for PostgreSQL and MinIO"
  type        = bool
  default     = false # Set to true for production
}

variable "postgres_storage_size" {
  description = "Storage size for PostgreSQL PVC"
  type        = string
  default     = "5Gi"
}

variable "minio_storage_size" {
  description = "Storage size for MinIO PVC"
  type        = string
  default     = "10Gi"
}
