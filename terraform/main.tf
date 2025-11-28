# Agricultural Monitoring Pipeline Infrastructure
# Terraform configuration for Kubernetes deployment
# Updated with complete Dagster deployment architecture

terraform {
  required_version = ">= 1.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
  }
}

# Kubernetes provider
# Uses local kubeconfig (Docker Desktop, minikube, or kind)
provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

# Create namespace for Agricultural Monitoring Pipeline application
resource "kubernetes_namespace" "agricultural_pipeline" {
  metadata {
    name = var.namespace

    labels = {
      app     = "agricultural-pipeline"
      managed = "terraform"
    }
  }
}

# Secret for PostgreSQL credentials
resource "kubernetes_secret" "postgres_credentials" {
  metadata {
    name      = "postgres-credentials"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name
  }

  data = {
    username = base64encode(var.postgres_user)
    password = base64encode(var.postgres_password)
    database = base64encode(var.postgres_db)
  }

  type = "Opaque"
}

# Secret for MinIO credentials
resource "kubernetes_secret" "minio_credentials" {
  metadata {
    name      = "minio-credentials"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name
  }

  data = {
    access_key = base64encode(var.minio_root_user)
    secret_key = base64encode(var.minio_root_password)
  }

  type = "Opaque"
}

# ConfigMap for fields configuration
resource "kubernetes_config_map" "fields_config" {
  metadata {
    name      = "fields-config"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name
  }

  data = {
    "fields.yaml" = file("${path.module}/../config/fields.yaml")
  }

  depends_on = [kubernetes_namespace.agricultural_pipeline]
}

# ConfigMap for Dagster instance configuration
resource "kubernetes_config_map" "dagster_instance" {
  metadata {
    name      = "dagster-instance"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name
  }

  data = {
    "dagster.yaml" = <<-EOT
run_storage:
  module: dagster_postgres.run_storage
  class: PostgresRunStorage
  config:
    postgres_url: postgresql://${var.postgres_user}:${var.postgres_password}@postgres:5432/${var.postgres_db}

event_log_storage:
  module: dagster_postgres.event_log
  class: PostgresEventLogStorage
  config:
    postgres_url: postgresql://${var.postgres_user}:${var.postgres_password}@postgres:5432/${var.postgres_db}

schedule_storage:
  module: dagster_postgres.schedule_storage
  class: PostgresScheduleStorage
  config:
    postgres_url: postgresql://${var.postgres_user}:${var.postgres_password}@postgres:5432/${var.postgres_db}

run_coordinator:
  module: dagster.core.run_coordinator
  class: QueuedRunCoordinator

run_launcher:
  module: dagster_k8s.launcher
  class: K8sRunLauncher
  config:
    service_account_name: dagster
    job_image: ${var.dagster_image}
    image_pull_policy: IfNotPresent
    instance_config_map: dagster-instance
    job_namespace: agricultural-pipeline
    env_config_maps:
      - fields-config
    env_secrets:
      - postgres-credentials
      - minio-credentials
    env_vars:
      - MINIO_ENDPOINT=minio:9000
EOT
  }

  depends_on = [kubernetes_namespace.agricultural_pipeline]
}

# ConfigMap for Dagster workspace configuration
resource "kubernetes_config_map" "dagster_workspace" {
  metadata {
    name      = "dagster-workspace"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name
  }

  data = {
    "workspace.yaml" = <<-EOT
      load_from:
        - grpc_server:
            host: dagster-code
            port: 4000
            location_name: "agricultural_location"
    EOT
  }

  depends_on = [kubernetes_namespace.agricultural_pipeline]
}

# Service Account for Dagster
resource "kubernetes_service_account" "dagster" {
  metadata {
    name      = "dagster"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name
  }

  depends_on = [kubernetes_namespace.agricultural_pipeline]
}

# Role for Dagster to launch K8s jobs
resource "kubernetes_role" "dagster_launcher" {
  metadata {
    name      = "dagster-launcher"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "pods/exec"]
    verbs      = ["get", "list", "watch", "create", "update", "delete"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list", "watch", "create", "update", "delete"]
  }

  depends_on = [kubernetes_namespace.agricultural_pipeline]
}

# RoleBinding for Dagster
resource "kubernetes_role_binding" "dagster_launcher" {
  metadata {
    name      = "dagster-launcher"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.dagster_launcher.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.dagster.metadata[0].name
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name
  }

  depends_on = [
    kubernetes_service_account.dagster,
    kubernetes_role.dagster_launcher
  ]
}

# Outputs for verification
output "namespace" {
  description = "Kubernetes namespace created"
  value       = kubernetes_namespace.agricultural_pipeline.metadata[0].name
}

output "kubeconfig_context" {
  description = "Kubernetes context in use"
  value       = var.kube_context
}

output "setup_instructions" {
  description = "Next steps to complete the deployment"
  sensitive   = true
  value       = <<-EOT
    
    Terraform infrastructure deployed successfully!
    
    Next steps:
    
    1. Wait for PostgreSQL to be ready:
       kubectl wait --for=condition=ready pod -l app=postgres -n ${kubernetes_namespace.agricultural_pipeline.metadata[0].name} --timeout=120s
    
    2. Wait for MinIO to be ready:
       kubectl wait --for=condition=ready pod -l app=minio -n ${kubernetes_namespace.agricultural_pipeline.metadata[0].name} --timeout=120s
    
    3. Wait for Dagster services to be ready:
       kubectl wait --for=condition=ready pod -l app=dagster-webserver -n ${kubernetes_namespace.agricultural_pipeline.metadata[0].name} --timeout=180s
    
    4. Access Dagster UI:
       - Webserver: http://localhost:3000
       - MinIO Console: http://localhost:9001 (credentials: ${var.minio_root_user}/${var.minio_root_password})
    
    5. Check pod status:
       kubectl get pods -n ${kubernetes_namespace.agricultural_pipeline.metadata[0].name}
    
    6. View logs if needed:
       kubectl logs -f deployment/dagster-webserver -n ${kubernetes_namespace.agricultural_pipeline.metadata[0].name}
       kubectl logs -f deployment/dagster-daemon -n ${kubernetes_namespace.agricultural_pipeline.metadata[0].name}
       kubectl logs -f deployment/dagster-code -n ${kubernetes_namespace.agricultural_pipeline.metadata[0].name}
  EOT
}
