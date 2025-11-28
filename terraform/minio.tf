# MinIO S3-compatible object storage deployment

# MinIO Deployment
resource "kubernetes_deployment" "minio" {
  metadata {
    name      = "minio"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name

    labels = {
      app = "minio"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "minio"
      }
    }

    template {
      metadata {
        labels = {
          app = "minio"
        }
      }

      spec {
        container {
          name  = "minio"
          image = "quay.io/minio/minio:latest"

          args = [
            "server",
            "/data",
            "--console-address",
            ":9001"
          ]

          env {
            name  = "MINIO_ROOT_USER"
            value = var.minio_root_user
          }

          env {
            name  = "MINIO_ROOT_PASSWORD"
            value = var.minio_root_password
          }

          port {
            name           = "api"
            container_port = 9000
            protocol       = "TCP"
          }

          port {
            name           = "console"
            container_port = 9001
            protocol       = "TCP"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          liveness_probe {
            http_get {
              path = "/minio/health/live"
              port = 9000
            }
            initial_delay_seconds = 30
            period_seconds        = 20
          }

          readiness_probe {
            http_get {
              path = "/minio/health/ready"
              port = 9000
            }
            initial_delay_seconds = 15
            period_seconds        = 10
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "2Gi"
            }
          }
        }

        volume {
          name = "data"

          empty_dir {}
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.agricultural_pipeline]
}

# MinIO Service (API)
resource "kubernetes_service" "minio_api" {
  metadata {
    name      = "minio"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name

    labels = {
      app = "minio"
    }
  }

  spec {
    type = "LoadBalancer"

    selector = {
      app = "minio"
    }

    port {
      name        = "api"
      port        = 9000
      target_port = 9000
      protocol    = "TCP"
    }
  }

  depends_on = [kubernetes_deployment.minio]
}

# MinIO Service (Console)
resource "kubernetes_service" "minio_console" {
  metadata {
    name      = "minio-console"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name

    labels = {
      app = "minio"
    }
  }

  spec {
    type = "LoadBalancer"

    selector = {
      app = "minio"
    }

    port {
      name        = "console"
      port        = 9001
      target_port = 9001
      protocol    = "TCP"
    }
  }

  depends_on = [kubernetes_deployment.minio]
}

# Outputs
output "minio_api_endpoint" {
  description = "MinIO API endpoint"
  value       = "http://localhost:9000"
}

output "minio_console_endpoint" {
  description = "MinIO Console endpoint"
  value       = "http://localhost:9001"
}
