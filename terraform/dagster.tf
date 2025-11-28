# Dagster data orchestration platform deployment
# Complete deployment with webserver, daemon, and code location

# PostgreSQL for Dagster metadata storage
resource "kubernetes_deployment" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name

    labels = {
      app = "postgres"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "postgres"
      }
    }

    template {
      metadata {
        labels = {
          app = "postgres"
        }
      }

      spec {
        container {
          name  = "postgres"
          image = "postgres:15-alpine"
          
          env {
            name  = "POSTGRES_USER"
            value = var.postgres_user
          }

          env {
            name  = "POSTGRES_PASSWORD"
            value = var.postgres_password
          }

          env {
            name  = "POSTGRES_DB"
            value = var.postgres_db
          }

          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }

          port {
            container_port = 5432
            protocol       = "TCP"
          }

          volume_mount {
            name       = "postgres-data"
            mount_path = "/var/lib/postgresql/data"
          }

          resources {
            requests = {
              cpu    = "200m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "2Gi"
            }
          }
          
                    liveness_probe {
            exec {
              command = ["pg_isready", "-U", "dagster"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 6
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "dagster"]
            }
            initial_delay_seconds = 10
            period_seconds        = 5
            timeout_seconds       = 5
            failure_threshold     = 6
          }
        }

        volume {
          name = "postgres-data"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    kubernetes_namespace.agricultural_pipeline,
    kubernetes_secret.postgres_credentials
  ]
}

# PostgreSQL Service
resource "kubernetes_service" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "postgres"
    }

    port {
      port        = 5432
      target_port = 5432
      protocol    = "TCP"
    }
  }

  depends_on = [kubernetes_deployment.postgres]
}

# Dagster Code Location (gRPC server that hosts your code)
resource "kubernetes_deployment" "dagster_code" {
  metadata {
    name      = "dagster-code"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name

    labels = {
      app = "dagster-code"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "dagster-code"
      }
    }

    template {
      metadata {
        labels = {
          app = "dagster-code"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.dagster.metadata[0].name

        container {
          name              = "dagster-code"
          image             = var.dagster_image
          image_pull_policy = var.dagster_image_pull_policy

          command = [
            "dagster",
            "api",
            "grpc",
            "-h",
            "0.0.0.0",
            "-p",
            "4000",
            "-m",
            "dagster_project"
          ]

          # Environment variables for PostgreSQL
          env {
            name  = "DAGSTER_POSTGRES_URL"
            value = "postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@postgres:5432/$(POSTGRES_DB)"
          }

          env {
            name  = "POSTGRES_USER"
            value = var.postgres_user
          }

          env {
            name  = "POSTGRES_PASSWORD"
            value = var.postgres_password
          }

          env {
            name  = "POSTGRES_DB"
            value = var.postgres_db
          }

          # Environment variables for MinIO
          env {
            name  = "MINIO_ENDPOINT"
            value = "minio:9000"
          }

          env {
            name = "MINIO_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.minio_credentials.metadata[0].name
                key  = "access_key"
              }
            }
          }

          env {
            name = "MINIO_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.minio_credentials.metadata[0].name
                key  = "secret_key"
              }
            }
          }

          # Configuration path
          env {
            name  = "CONFIG_PATH"
            value = "/config/fields.yaml"
          }

          port {
            name           = "grpc"
            container_port = 4000
            protocol       = "TCP"
          }

          volume_mount {
            name       = "fields-config"
            mount_path = "/config"
            read_only  = true
          }

         liveness_probe {
  exec {
    command = [
      "dagster",
      "api",
      "grpc-health-check",
      "-p",
      "4000"
    ]
  }
  initial_delay_seconds = 180      
  period_seconds        = 30
  timeout_seconds       = 60      
  failure_threshold     = 10
}

readiness_probe {
  exec {
    command = [
      "dagster",
      "api",
      "grpc-health-check",
      "-p",
      "4000"
    ]
  }
  initial_delay_seconds = 120     
  period_seconds        = 30      
  timeout_seconds       = 60       
  failure_threshold     = 10
}
        }

        volume {
          name = "fields-config"
          config_map {
            name = kubernetes_config_map.fields_config.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.postgres,
    kubernetes_secret.postgres_credentials,
    kubernetes_secret.minio_credentials,
    kubernetes_config_map.fields_config,
    kubernetes_service_account.dagster
  ]
}

# Dagster Code Location Service
resource "kubernetes_service" "dagster_code" {
  metadata {
    name      = "dagster-code"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name

    labels = {
      app = "dagster-code"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "dagster-code"
    }

    port {
      name        = "grpc"
      port        = 4000
      target_port = 4000
      protocol    = "TCP"
    }
  }

  depends_on = [kubernetes_deployment.dagster_code]
}

# Dagster Daemon (handles schedules, sensors, run queue)
resource "kubernetes_deployment" "dagster_daemon" {
  metadata {
    name      = "dagster-daemon"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name

    labels = {
      app = "dagster-daemon"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "dagster-daemon"
      }
    }

    template {
      metadata {
        labels = {
          app = "dagster-daemon"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.dagster.metadata[0].name

        container {
          name              = "dagster-daemon"
          image             = var.dagster_image
          image_pull_policy = var.dagster_image_pull_policy

          command = [
            "dagster-daemon",
            "run"
          ]

          # Environment variables for PostgreSQL
          env {
            name  = "DAGSTER_POSTGRES_URL"
            value = "postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@postgres:5432/$(POSTGRES_DB)"
          }

          env {
            name  = "POSTGRES_USER"
            value = var.postgres_user
          }

          env {
            name  = "POSTGRES_PASSWORD"
            value = var.postgres_password
          }

          env {
            name  = "POSTGRES_DB"
            value = var.postgres_db
          }

          # Environment variables for MinIO
          env {
            name  = "MINIO_ENDPOINT"
            value = "minio:9000"
          }

          env {
            name = "MINIO_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.minio_credentials.metadata[0].name
                key  = "access_key"
              }
            }
          }

          env {
            name = "MINIO_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.minio_credentials.metadata[0].name
                key  = "secret_key"
              }
            }
          }

          env {
            name  = "CONFIG_PATH"
            value = "/config/fields.yaml"
          }

          env {
            name  = "DAGSTER_HOME"
            value = "/opt/dagster/dagster_home"
          }

          volume_mount {
            name       = "dagster-instance"
            mount_path = "/opt/dagster/dagster_home/dagster.yaml"
            sub_path   = "dagster.yaml"
          }

          volume_mount {
            name       = "fields-config"
            mount_path = "/config"
            read_only  = true
          }


          liveness_probe {
            exec {
              command = [
                "sh",
                "-c",
                "dagster-daemon liveness-check"
              ]
            }
            initial_delay_seconds = 120
            period_seconds        = 30
            timeout_seconds       = 15
            failure_threshold     = 10
          }
        }

        volume {
          name = "dagster-instance"
          config_map {
            name = kubernetes_config_map.dagster_instance.metadata[0].name
          }
        }

        volume {
          name = "fields-config"
          config_map {
            name = kubernetes_config_map.fields_config.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.postgres,
    kubernetes_secret.postgres_credentials,
    kubernetes_secret.minio_credentials,
    kubernetes_config_map.dagster_instance,
    kubernetes_config_map.fields_config,
    kubernetes_service_account.dagster,
    kubernetes_role_binding.dagster_launcher
  ]
}

# Dagster Webserver Deployment
resource "kubernetes_deployment" "dagster_webserver" {
  metadata {
    name      = "dagster-webserver"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name

    labels = {
      app = "dagster-webserver"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "dagster-webserver"
      }
    }

    template {
      metadata {
        labels = {
          app = "dagster-webserver"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.dagster.metadata[0].name

        container {
          name              = "dagster-webserver"
          image             = var.dagster_image
          image_pull_policy = var.dagster_image_pull_policy

          command = [
            "dagster-webserver",
            "-h",
            "0.0.0.0",
            "-p",
            "3000",
            "-w",
            "/opt/dagster/workspace.yaml"
          ]

          # Environment variables for PostgreSQL
          env {
            name  = "DAGSTER_POSTGRES_URL"
            value = "postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@postgres:5432/$(POSTGRES_DB)"
          }

          env {
            name  = "POSTGRES_USER"
            value = var.postgres_user
          }

          env {
            name  = "POSTGRES_PASSWORD"
            value = var.postgres_password
          }

          env {
            name  = "POSTGRES_DB"
            value = var.postgres_db
          }

          # Environment variables for MinIO
          env {
            name  = "MINIO_ENDPOINT"
            value = "minio:9000"
          }

          env {
            name = "MINIO_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.minio_credentials.metadata[0].name
                key  = "access_key"
              }
            }
          }

          env {
            name = "MINIO_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.minio_credentials.metadata[0].name
                key  = "secret_key"
              }
            }
          }

          env {
            name  = "CONFIG_PATH"
            value = "/config/fields.yaml"
          }

          env {
            name  = "DAGSTER_HOME"
            value = "/opt/dagster/dagster_home"
          }

          port {
            name           = "http"
            container_port = 3000
            protocol       = "TCP"
          }

          volume_mount {
            name       = "dagster-instance"
            mount_path = "/opt/dagster/dagster_home/dagster.yaml"
            sub_path   = "dagster.yaml"
          }

          volume_mount {
            name       = "dagster-workspace"
            mount_path = "/opt/dagster/workspace.yaml"
            sub_path   = "workspace.yaml"
          }

          volume_mount {
            name       = "fields-config"
            mount_path = "/config"
            read_only  = true
          }

          liveness_probe {
            http_get {
              path = "/server_info"
              port = 3000
            }
            initial_delay_seconds = 180
            period_seconds        = 30
            timeout_seconds       = 15
            failure_threshold     = 10
          }

          readiness_probe {
            http_get {
              path = "/server_info"
              port = 3000
            }
            initial_delay_seconds = 120
            period_seconds        = 20
            timeout_seconds       = 15
            failure_threshold     = 10
          }
        }

        volume {
          name = "dagster-instance"
          config_map {
            name = kubernetes_config_map.dagster_instance.metadata[0].name
          }
        }

        volume {
          name = "dagster-workspace"
          config_map {
            name = kubernetes_config_map.dagster_workspace.metadata[0].name
          }
        }

        volume {
          name = "fields-config"
          config_map {
            name = kubernetes_config_map.fields_config.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.postgres,
    kubernetes_deployment.dagster_code,
    kubernetes_secret.postgres_credentials,
    kubernetes_secret.minio_credentials,
    kubernetes_config_map.dagster_instance,
    kubernetes_config_map.dagster_workspace,
    kubernetes_config_map.fields_config,
    kubernetes_service_account.dagster
  ]
}

# Dagster Webserver Service
resource "kubernetes_service" "dagster_webserver" {
  metadata {
    name      = "dagster-webserver"
    namespace = kubernetes_namespace.agricultural_pipeline.metadata[0].name

    labels = {
      app = "dagster-webserver"
    }
  }

  spec {
    type = "LoadBalancer"

    selector = {
      app = "dagster-webserver"
    }

    port {
      name        = "http"
      port        = 3000
      target_port = 3000
      protocol    = "TCP"
    }
  }

  depends_on = [kubernetes_deployment.dagster_webserver]
}

# Outputs
output "dagster_webserver_endpoint" {
  description = "Dagster webserver endpoint"
  value       = "http://localhost:3000"
}

output "dagster_services_status" {
  description = "Commands to check Dagster services status"
  value       = <<-EOT
    Check deployment status:
      kubectl get deployments -n ${kubernetes_namespace.agricultural_pipeline.metadata[0].name}
    
    Check pod status:
      kubectl get pods -n ${kubernetes_namespace.agricultural_pipeline.metadata[0].name}
    
    View webserver logs:
      kubectl logs -f deployment/dagster-webserver -n ${kubernetes_namespace.agricultural_pipeline.metadata[0].name}
    
    View daemon logs:
      kubectl logs -f deployment/dagster-daemon -n ${kubernetes_namespace.agricultural_pipeline.metadata[0].name}
    
    View code location logs:
      kubectl logs -f deployment/dagster-code -n ${kubernetes_namespace.agricultural_pipeline.metadata[0].name}
  EOT
}
