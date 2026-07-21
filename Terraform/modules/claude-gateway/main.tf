data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  oidc_id       = replace(var.oidc_provider_url, "https://", "")
  gw_hostname   = lookup(var.claude_gateway, "gateway_hostname", "claude-gw.internal.example.com")
  gw_replicas   = lookup(var.claude_gateway, "gateway_replicas", 1)
  gw_version    = lookup(var.claude_gateway, "gateway_version", "2.1.195")
  ecr_repo_url  = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"
  namespace     = lookup(var.claude_gateway, "namespace", "claude-system")
  ingress_group = lookup(var.claude_gateway, "ingress_group", "${var.default["project"]}-${var.default["env"]}-claude")

  gateway_image = lookup(var.claude_gateway, "gateway_image",
    "${local.ecr_repo_url}/${var.default["project"]}-claude-gateway:${local.gw_version}"
  )

  pg_password    = lookup(var.claude_gateway, "pg_password", "REPLACE_WITH_STRONG_PASSWORD")
  pg_db          = "gateway"
  pg_user        = "gateway"
  pg_host        = "postgres.${local.namespace}.svc.cluster.local"
  pg_url         = "postgres://${local.pg_user}:${local.pg_password}@${local.pg_host}:5432/${local.pg_db}?sslmode=disable"

  # Feature flags
  # monitoring_enabled: deploys Loki, Grafana, log-forwarder, and OTel sidecar.
  #   Set to false for a lean deployment with no observability stack.
  monitoring_enabled = lookup(var.claude_gateway, "monitoring_enabled", true)

  # ttl_proxy_enabled: deploys the ttl-proxy sidecar that strips cache_control.ttl
  #   from requests. Required for Claude 3.x APAC Bedrock models ("Extra inputs not
  #   permitted" error). Safe to disable if only Claude 4.x global profiles are used.
  ttl_proxy_enabled  = lookup(var.claude_gateway, "ttl_proxy_enabled", true)

  cert_manager_enabled = false
}

# ─── TLS: Self-signed fallback certificate → ACM ─────────────────────────────
# Used only if acm_certificate_arn is not provided in tfvars.
# For production, always set acm_certificate_arn to a DNS-validated ACM cert.

resource "tls_private_key" "claude_gateway" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "claude_gateway" {
  private_key_pem = tls_private_key.claude_gateway.private_key_pem

  subject {
    common_name = "claude-gateway"
  }

  dns_names = [local.gw_hostname]

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "cert_signing",
  ]
}

resource "aws_acm_certificate" "claude_gateway" {
  private_key       = tls_private_key.claude_gateway.private_key_pem
  certificate_body  = tls_self_signed_cert.claude_gateway.cert_pem

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  acm_cert_arn = lookup(var.claude_gateway, "acm_certificate_arn", "") != "" ? lookup(var.claude_gateway, "acm_certificate_arn", "") : aws_acm_certificate.claude_gateway.arn
}

# ─── ECR Repository ───────────────────────────────────────────────────────────

resource "aws_ecr_repository" "claude_gateway" {
  name                 = "${var.default["project"]}-claude-gateway"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "claude_gateway" {
  repository = aws_ecr_repository.claude_gateway.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# ─── Namespace: claude-system ─────────────────────────────────────────────────

resource "kubernetes_namespace" "claude_system" {
  metadata {
    name = "claude-system"
    labels = {
      env     = var.default["env"]
      project = var.default["project"]
      "pod-security.kubernetes.io/enforce"         = "baseline"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/audit"           = "baseline"
      "pod-security.kubernetes.io/warn"            = "baseline"
    }
  }
}

# ─── StorageClass: gp3 ────────────────────────────────────────────────────────

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  reclaim_policy         = "Retain"
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}

# ─── IRSA: claude-gateway (Bedrock) ───────────────────────────────────────────

resource "aws_iam_role" "claude_gateway" {
  name = "${var.default["env"]}-${var.default["project"]}-claude-gateway-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_id}:sub" = "system:serviceaccount:claude-system:claude-gateway"
          "${local.oidc_id}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "claude_gateway" {
  name = "${var.default["env"]}-${var.default["project"]}-claude-gateway-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:ListFoundationModels",
          "bedrock:GetFoundationModel",
          "bedrock:GetInferenceProfile",
          "bedrock:ListInferenceProfiles",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "claude_gateway" {
  role       = aws_iam_role.claude_gateway.name
  policy_arn = aws_iam_policy.claude_gateway.arn
}

# ─── ServiceAccount ───────────────────────────────────────────────────────────

resource "kubernetes_service_account" "claude_gateway" {
  metadata {
    name      = "claude-gateway"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.claude_gateway.arn
    }
  }
}

# ─── Postgres (in-cluster session store) ─────────────────────────────────────

resource "kubernetes_secret" "postgres" {
  metadata {
    name      = "postgres-secret"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }
  data = {
    POSTGRES_PASSWORD = local.pg_password
    POSTGRES_USER     = local.pg_user
    POSTGRES_DB       = local.pg_db
  }
}

resource "kubernetes_persistent_volume_claim_v1" "postgres_data" {
  metadata {
    name      = "postgres-data"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.gp3.metadata[0].name
    resources {
      requests = { storage = "10Gi" }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_deployment" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
    labels    = { app = "postgres" }
  }

  spec {
    replicas = 1
    selector { match_labels = { app = "postgres" } }

    strategy {
      type = "Recreate"
    }

    template {
      metadata { labels = { app = "postgres" } }

      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 999
          run_as_group    = 999
          fs_group        = 999
          seccomp_profile { type = "RuntimeDefault" }
        }

        container {
          name  = "postgres"
          image = "postgres:16-alpine"

          env_from {
            secret_ref { name = kubernetes_secret.postgres.metadata[0].name }
          }

          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }

          port { container_port = 5432 }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
          volume_mount {
            name       = "run"
            mount_path = "/var/run/postgresql"
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          liveness_probe {
            exec { command = ["pg_isready", "-U", local.pg_user] }
            initial_delay_seconds = 15
            period_seconds        = 10
          }

          readiness_probe {
            exec { command = ["pg_isready", "-U", local.pg_user] }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities { drop = ["ALL"] }
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.postgres_data.metadata[0].name
          }
        }
        volume {
          name = "tmp"
          empty_dir {}
        }
        volume {
          name = "run"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [kubernetes_persistent_volume_claim_v1.postgres_data]
}

resource "kubernetes_service" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }
  spec {
    selector = { app = "postgres" }
    port {
      port        = 5432
      target_port = 5432
    }
  }
}


# ─── OpenTelemetry Collector (in-cluster log sink) ───────────────────────────
# Receives OTLP from the gateway, writes structured JSON to stdout.
# Gateway is the OTLP proxy for clients — clients send telemetry to the gateway's
# public URL; gateway forwards to this collector internally.
# Logs are visible via: kubectl logs -n claude-system -l app=otel-collector -f

resource "kubernetes_config_map" "otel_collector" {
  count = local.monitoring_enabled ? 1 : 0
  metadata {
    name      = "otel-collector-config"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }

  data = {
    # Plain YAML — filelog receiver removed (hostPath blocked by PodSecurity;
    # gateway logs are collected by the log-forwarder pod instead).
    # OTel sidecar handles only OTLP signals forwarded by the gateway process.
    "otelcol.yaml" = <<-YAML
extensions:
  health_check:
    endpoint: 0.0.0.0:13133

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:4317
      http:
        endpoint: 127.0.0.1:4318

processors:
  batch:
    timeout: 5s
    send_batch_size: 100

exporters:
  otlphttp:
    endpoint: http://loki.claude-system.svc.cluster.local:3100/otlp
    tls:
      insecure: true

service:
  extensions: [health_check]
  telemetry:
    logs:
      level: error
  pipelines:
    logs/otlp:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlphttp]
YAML
  }
}

# ─── Loki (log storage) ───────────────────────────────────────────────────────

resource "kubernetes_config_map" "loki" {
  count = local.monitoring_enabled ? 1 : 0
  metadata {
    name      = "loki-config"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }

  data = {
    "loki.yaml" = <<-YAML
auth_enabled: false
server:
  http_listen_port: 3100
  log_level: warn
ingester:
  chunk_idle_period: 5m
  chunk_retain_period: 1m
  max_chunk_age: 1h
  lifecycler:
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
    availability_zone: zone-a
    num_tokens: 128
  wal:
    enabled: false
distributor:
  ring:
    kvstore:
      store: inmemory
schema_config:
  configs:
  - from: 2024-01-01
    store: tsdb
    object_store: filesystem
    schema: v13
    index:
      prefix: index_
      period: 24h
storage_config:
  tsdb_shipper:
    active_index_directory: /loki/index
    cache_location: /loki/index_cache
  filesystem:
    directory: /loki/chunks
compactor:
  working_directory: /loki/compactor
limits_config:
  retention_period: 720h
  shard_streams:
    enabled: false
YAML
  }
}

resource "kubernetes_persistent_volume_claim_v1" "loki_data" {
  count = local.monitoring_enabled ? 1 : 0
  metadata {
    name      = "loki-data"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.gp3.metadata[0].name
    resources {
      requests = { storage = "20Gi" }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_deployment" "loki" {
  count = local.monitoring_enabled ? 1 : 0
  metadata {
    name      = "loki"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
    labels    = { app = "loki" }
  }

  spec {
    replicas = 1
    selector { match_labels = { app = "loki" } }
    strategy { type = "Recreate" }

    template {
      metadata { labels = { app = "loki" } }

      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 10001
          run_as_group    = 10001
          fs_group        = 10001
          seccomp_profile { type = "RuntimeDefault" }
        }

        container {
          name    = "loki"
          image   = "grafana/loki:3.1.0"
          args    = ["-config.file=/etc/loki/loki.yaml"]

          port {
            name           = "http"
            container_port = 3100
          }
          port {
            name           = "grpc"
            container_port = 9095
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/loki"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/loki"
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = 3100
            }
            initial_delay_seconds = 15
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/ready"
              port = 3100
            }
            initial_delay_seconds = 30
            period_seconds        = 15
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities { drop = ["ALL"] }
          }
        }

        volume {
          name = "config"
          config_map { name = kubernetes_config_map.loki[count.index].metadata[0].name }
        }
        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.loki_data[count.index].metadata[0].name }
        }
        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [kubernetes_persistent_volume_claim_v1.loki_data]
}

resource "kubernetes_service" "loki" {
  count = local.monitoring_enabled ? 1 : 0
  metadata {
    name      = "loki"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }
  spec {
    selector = { app = "loki" }
    type     = "ClusterIP"
    port {
      name        = "http"
      port        = 3100
      target_port = 3100
    }
  }
}


# ─── Log Forwarder (Python pod → Loki) ────────────────────────────────────────
# Uses Kubernetes API to read gateway pod logs and push them to Loki via HTTP.
# Deployed as a standalone pod that queries the API every 30s.

resource "kubernetes_config_map" "log_forwarder_script" {
  count = local.monitoring_enabled ? 1 : 0
  metadata {
    name      = "log-forwarder-script"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }

  data = {
    # Use enhanced version that parses User-Agent and extracts tool/surface info
    "forwarder.py" = file("${path.module}/log-forwarder-enhanced.py")
  }
}

resource "kubernetes_service_account" "log_forwarder" {
  count = local.monitoring_enabled ? 1 : 0
  metadata {
    name      = "log-forwarder"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }
}

resource "kubernetes_role" "log_forwarder" {
  count = local.monitoring_enabled ? 1 : 0
  metadata {
    name      = "log-forwarder"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding" "log_forwarder" {
  count = local.monitoring_enabled ? 1 : 0
  metadata {
    name      = "log-forwarder"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.log_forwarder[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.log_forwarder[0].metadata[0].name
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }
}

resource "kubernetes_deployment" "log_forwarder" {
  count = local.monitoring_enabled ? 1 : 0
  metadata {
    name      = "log-forwarder"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
    labels    = { app = "log-forwarder" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "log-forwarder" }
    }

    template {
      metadata {
        labels = { app = "log-forwarder" }
      }

      spec {
        service_account_name = kubernetes_service_account.log_forwarder[0].metadata[0].name

        container {
          name              = "forwarder"
          image             = "python:3.12-alpine"
          image_pull_policy = "IfNotPresent"
          command           = ["python3", "-u", "/app/forwarder.py"]

          volume_mount {
            name       = "script"
            mount_path = "/app"
          }

          volume_mount {
            name       = "sa-token"
            mount_path = "/run/secrets/kubernetes.io/serviceaccount"
            read_only  = true
          }

          env {
            name  = "LOKI_HOST"
            value = "loki"
          }
          env {
            name  = "LOKI_PORT"
            value = "3100"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
        }

        volume {
          name = "script"
          config_map {
            name         = kubernetes_config_map.log_forwarder_script[0].metadata[0].name
            default_mode = "0755"
          }
        }

        volume {
          name = "sa-token"
          projected {
            sources {
              service_account_token {
                path = "token"
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_role_binding.log_forwarder[0]]
}

# ─── Grafana (log viewer UI) ──────────────────────────────────────────────────

resource "kubernetes_config_map" "grafana_datasources" {
  count = local.monitoring_enabled ? 1 : 0
  metadata {
    name      = "grafana-datasources"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
    labels    = { "grafana_datasource" = "1" }
  }

  data = {
    "datasources.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Loki"
        type      = "loki"
        access    = "proxy"
        url       = "http://loki.claude-system.svc.cluster.local:3100"
        isDefault = true
        jsonData  = { maxLines = 5000 }
      }]
    })
  }
}

resource "kubernetes_config_map" "grafana_dashboards_provider" {
  count = local.monitoring_enabled ? 1 : 0
  metadata {
    name      = "grafana-dashboards-provider"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }

  data = {
    "provider.yaml" = yamlencode({
      apiVersion = 1
      providers = [{
        name            = "default"
        type            = "file"
        disableDeletion = false
        updateIntervalSeconds = 30
        options = { path = "/var/lib/grafana/dashboards" }
      }]
    })
  }
}

resource "kubernetes_config_map" "grafana_dashboard_claude" {
  count = local.monitoring_enabled ? 1 : 0
  metadata {
    name      = "grafana-dashboard-claude"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }

  data = {
    "claude-gateway.json"      = file("${path.module}/grafana-dashboard.json")
    "claude-otel-signals.json" = file("${path.module}/grafana-dashboard-otel.json")
  }
}


resource "kubernetes_persistent_volume_claim_v1" "grafana_data" {
  count = local.monitoring_enabled ? 1 : 0
  metadata {
    name      = "grafana-data"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.gp3.metadata[0].name
    resources {
      requests = { storage = "5Gi" }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_deployment" "grafana" {
  count = local.monitoring_enabled ? 1 : 0
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
    labels    = { app = "grafana" }
  }

  spec {
    replicas = 1
    selector { match_labels = { app = "grafana" } }
    strategy { type = "Recreate" }

    template {
      metadata { labels = { app = "grafana" } }

      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 472
          run_as_group    = 472
          fs_group        = 472
          seccomp_profile { type = "RuntimeDefault" }
        }

        container {
          name  = "grafana"
          image = "grafana/grafana:11.1.0"

          port {
            name           = "http"
            container_port = 3000
          }

          env {
            name  = "GF_SECURITY_ADMIN_USER"
            value = "admin"
          }
          env {
            name  = "GF_SECURITY_ADMIN_PASSWORD"
            value = lookup(var.claude_gateway, "grafana_admin_password", "admin")
          }
          env {
            name  = "GF_AUTH_ANONYMOUS_ENABLED"
            value = "false"
          }
          env {
            name  = "GF_SERVER_ROOT_URL"
            value = "%(protocol)s://%(domain)s/grafana"
          }
          env {
            name  = "GF_SERVER_SERVE_FROM_SUB_PATH"
            value = "true"
          }

          volume_mount {
            name       = "datasources"
            mount_path = "/etc/grafana/provisioning/datasources"
            read_only  = true
          }
          volume_mount {
            name       = "dashboards-provider"
            mount_path = "/etc/grafana/provisioning/dashboards"
            read_only  = true
          }
          volume_mount {
            name       = "dashboards"
            mount_path = "/var/lib/grafana/dashboards"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/grafana"
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          readiness_probe {
            http_get {
              path = "/grafana/api/health"
              port = 3000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities { drop = ["ALL"] }
          }
        }

        volume {
          name = "datasources"
          config_map { name = kubernetes_config_map.grafana_datasources[0].metadata[0].name }
        }
        volume {
          name = "dashboards-provider"
          config_map { name = kubernetes_config_map.grafana_dashboards_provider[0].metadata[0].name }
        }
        volume {
          name = "dashboards"
          config_map { name = kubernetes_config_map.grafana_dashboard_claude[0].metadata[0].name }
        }
        volume {
          name = "data"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.grafana_data[0].metadata[0].name }
        }
        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.loki,
    kubernetes_persistent_volume_claim_v1.grafana_data[0],
  ]
}

resource "kubernetes_service" "grafana" {
  count = local.monitoring_enabled ? 1 : 0
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }
  spec {
    selector = { app = "grafana" }
    type     = "ClusterIP"
    port {
      name        = "http"
      port        = 3000
      target_port = 3000
    }
  }
}

# OTel collector runs as a sidecar inside the claude-gateway pod (see deployment above).
# No standalone deployment or service needed — loopback (127.0.0.1:4318) is used.

# ─── ConfigMap: nginx access-log sidecar ─────────────────────────────────────
# nginx sits in front of the gateway on port 8080, proxies to 8081, and logs
# the User-Agent so we can identify Chat vs Code vs Cowork vs CLI.
# Log format: JSON line per request with request_id, user_agent, status, method, path.
# ─── ConfigMap: ttl-proxy script ─────────────────────────────────────────────
# Python proxy that strips cache_control.ttl before forwarding to gateway.
# Claude 3.x APAC models on Bedrock reject the ttl field.
resource "kubernetes_config_map" "ttl_proxy_script" {
  metadata {
    name      = "ttl-proxy-script"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }

  data = {
    "proxy.py" = <<-PROXY
      #!/usr/bin/env python3
      """
      TTL proxy: strips cache_control.ttl from /v1/messages requests.
      Claude 3.x on Bedrock APAC rejects ttl (Claude 4.x only field).
      Listens 8082, forwards to gateway 8081.
      """
      import re, http.server, http.client
      from datetime import datetime, timezone

      GATEWAY_PORT = 8081
      LISTEN_PORT  = 8082
      TTL_RE = re.compile(rb',?\s*"ttl"\s*:\s*(?:"[^"]*"|\d+)\s*')

      class ProxyHandler(http.server.BaseHTTPRequestHandler):
          def log_message(self, *_): pass
          def do_request(self):
              length = int(self.headers.get("Content-Length", 0))
              body   = self.rfile.read(length) if length else b""
              has_ttl = False
              if self.path.startswith("/v1/messages") and body:
                  has_ttl = bool(TTL_RE.search(body))
                  new = TTL_RE.sub(b'', body)
                  if new != body:
                      body = new
                      print("[TTL] Stripped ttl field", flush=True)
              headers = {k: v for k, v in self.headers.items()
                         if k.lower() not in ("host","connection","transfer-encoding")}
              headers["Content-Length"] = str(len(body))
              headers["Host"] = f"127.0.0.1:{GATEWAY_PORT}"
              headers["X-Has-Cache-TTL"] = "yes" if has_ttl else "no"
              try:
                  conn = http.client.HTTPConnection("127.0.0.1", GATEWAY_PORT, timeout=300)
                  conn.request(self.command, self.path, body, headers)
                  resp = conn.getresponse()
                  self.send_response(resp.status)
                  for k, v in resp.getheaders():
                      if k.lower() not in ("connection","transfer-encoding"):
                          self.send_header(k, v)
                  self.end_headers()
                  while True:
                      chunk = resp.read(65536)
                      if not chunk: break
                      self.wfile.write(chunk)
                  conn.close()
              except Exception as e:
                  print(f"[{datetime.now(timezone.utc).isoformat()}] Error: {e}", flush=True)
                  self.send_error(502, str(e))
          do_GET = do_POST = do_HEAD = do_OPTIONS = do_request

      print(f"TTL proxy {LISTEN_PORT} -> gateway {GATEWAY_PORT}", flush=True)
      http.server.ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), ProxyHandler).serve_forever()
    PROXY
  }
}

resource "kubernetes_config_map" "nginx_access_log" {
  metadata {
    name      = "nginx-access-log-config"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }

  data = {
    "nginx.conf" = <<-NGINX
      worker_processes 1;
      error_log /dev/stderr error;
      pid /var/run/nginx.pid;

      events { worker_connections 256; }

      http {
        # Enable request body buffering for surface detection (chat vs cowork)
        client_body_buffer_size 10m;
        client_max_body_size 10m;

        # Detect Claude Code CLI: sends native Bash tool (NOT mcp__workspace__bash)
        map $request_body $is_claude_code {
          "~*\"name\"\s*:\s*\"Bash\""  "yes";
          default "no";
        }

        # Detect cowork by presence of Agent/TaskCreate tools in request
        map $request_body $is_cowork {
          "~*\"name\"\s*:\s*\"(?:Agent|TaskCreate|TaskGet|TaskList|TaskUpdate|Glob|Grep|Skill)\"" "yes";
          default "no";
        }

        log_format access_json escape=json
          '{"ts":"$time_iso8601"'
          ',"request_id":"$upstream_http_x_request_id"'
          ',"method":"$request_method"'
          ',"path":"$uri"'
          ',"status":$status'
          ',"user_agent":"$http_user_agent"'
          ',"surface":"$surface"'
          ',"bytes_sent":$bytes_sent'
          ',"upstream_ms":$upstream_response_time}';

        map $http_user_agent $surface_ua {
          "~*Claude for Desktop[^\(]*\(chat\)"         "chat";
          "~*Claude for Desktop[^\(]*\(code\)"         "code";
          "~*Claude for Desktop[^\(]*\(cowork\)"       "cowork";
          "~*claude-cli.*external.*local-agent"        "chat";
          "~*claude-cli.*external.*claude-desktop-3p"  "code";
          "~*claude-cli"                               "cli";
          "~*Mozilla.*AppleWebKit"                     "desktop-webview";
          "~*ELB-HealthChecker"                        "healthcheck";
          "~*curl"                                     "healthcheck";
          default                                      "unknown";
        }

        # Override surface based on request body signals:
        # 1. local-agent + native Bash tool → claude-code CLI
        # 2. local-agent + Agent/Task tools → cowork
        # 3. otherwise → keep UA-derived surface
        map "$surface_ua:$is_claude_code:$is_cowork" $surface {
          "chat:yes:yes"  "cli";
          "chat:yes:no"   "cli";
          "chat:no:yes"   "cowork";
          default         $surface_ua;
        }

        access_log /dev/stdout access_json;

        server {
          listen 8080;

          location / {
            proxy_pass         http://127.0.0.1:${local.ttl_proxy_enabled ? 8082 : 8081};
            proxy_set_header   Host              $host;
            proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
            proxy_buffering    off;
          }
        }
      }
    NGINX
  }
}

# ─── ConfigMap: claude-gateway ────────────────────────────────────────────────

resource "kubernetes_config_map" "claude_gateway" {
  metadata {
    name      = "claude-gateway-config"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }

  data = {
    "gateway.yaml" = replace(yamlencode({
      listen = {
        host       = "0.0.0.0"
        port       = 8081   # nginx sidecar on 8080 proxies here
        public_url = lookup(var.claude_gateway, "gateway_public_url", "https://${local.gw_hostname}")
      }

      oidc = {
          # JumpCloud direct OIDC — validates JWT access tokens via JWKS
          # Trailing slash required — JumpCloud discovery returns issuer with trailing slash
          issuer            = "https://oauth.id.jumpcloud.com/"
          client_id         = lookup(var.claude_gateway, "jumpcloud_client_id", "")
          client_secret     = lookup(var.claude_gateway, "jumpcloud_client_secret", "")
          userinfo_fallback = true
        }

      session = {
        jwt_secret = "$${GATEWAY_JWT_SECRET}"
        ttl_hours  = lookup(var.claude_gateway, "session_ttl_hours", 24)
      }

      store = {
        postgres_url = "$${GATEWAY_POSTGRES_URL}"
      }

      # OTel collector runs as a sidecar in this pod — reached via loopback.
      # CLAUDE_GATEWAY_ALLOW_LOOPBACK=1 env var (set on the container) permits http:// for 127.0.0.1.
      telemetry = {
        forward_to = [{
          url     = "http://127.0.0.1:4318"
          metrics = true
          logs    = true
          traces  = false
        }]
      }

      # Managed policies: pushed to every connected client at session start.
      # These env vars unlock full input/output logging in the OTEL events.
      managed = {
        policies = [{
          cli = {
            env = {
              # Enable telemetry and route it back through the gateway
              CLAUDE_CODE_ENABLE_TELEMETRY        = "1"
              OTEL_METRICS_EXPORTER               = "otlp"
              OTEL_LOGS_EXPORTER                  = "otlp"
              OTEL_EXPORTER_OTLP_ENDPOINT         = "https://${local.gw_hostname}"
              # Populate app.entrypoint attribute (cli / sdk-ts / claude-vscode)
              OTEL_METRICS_INCLUDE_ENTRYPOINT     = "true"
              # Full I/O logging
              OTEL_LOG_USER_PROMPTS               = "1"
              OTEL_LOG_ASSISTANT_RESPONSES        = "1"
              OTEL_LOG_TOOL_DETAILS               = "1"
            }
          }
        }]
      }

      upstreams = [{
        provider = "bedrock"
        region   = lookup(var.claude_gateway, "bedrock_region", var.default["region"])
        auth     = {}
      }]

      auto_include_builtin_models = true

      # Inference profile routing strategy:
      #   Claude 4.x family → global. profiles (no APAC geo profiles exist for these)
      #   Claude 3.x family → apac. profiles when deploying in APAC regions
      #
      # NOTE: versioned APAC profiles (e.g. apac.anthropic.claude-sonnet-4-20250514-v1:0)
      # can be suspended by Bedrock when unused for 30 days ("Legacy" error).
      # Use global.anthropic.claude-sonnet-4-6 which always resolves to the active model.
      #
      # Source: https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-support.html
      models = [
        # ── Global inference profiles (Claude 4.x family) ──────────────────
        { id = "claude-sonnet-4-6",                        upstream_model = { bedrock = "global.anthropic.claude-sonnet-4-6" } },
        { id = "claude-opus-4-8",                          upstream_model = { bedrock = "global.anthropic.claude-opus-4-8" } },
        { id = "claude-sonnet-5",                          upstream_model = { bedrock = "global.anthropic.claude-sonnet-5" } },
        { id = "claude-haiku-4-5-20251001",                upstream_model = { bedrock = "global.anthropic.claude-haiku-4-5-20251001-v1:0" } },

        # ── APAC inference profiles (Claude 3.x family) ──────────────────────
        # Routes requests within APAC regions (ap-south-1, ap-northeast-*, ap-southeast-*)
        # claude-sonnet-4 APAC is LEGACY (suspended by Anthropic) — excluded
        { id = "claude-3-7-sonnet-apac",                   upstream_model = { bedrock = "apac.anthropic.claude-3-7-sonnet-20250219-v1:0" } },
        { id = "claude-3-5-sonnet-v2-apac",                upstream_model = { bedrock = "apac.anthropic.claude-3-5-sonnet-20241022-v2:0" } },
        { id = "claude-3-5-sonnet-apac",                   upstream_model = { bedrock = "apac.anthropic.claude-3-5-sonnet-20240620-v1:0" } },
        { id = "claude-3-haiku-apac",                      upstream_model = { bedrock = "apac.anthropic.claude-3-haiku-20240307-v1:0" } },
        { id = "claude-3-sonnet-apac",                     upstream_model = { bedrock = "apac.anthropic.claude-3-sonnet-20240229-v1:0" } },
      ]
    }), "\"userinfo_fallback\": \"true\"", "\"userinfo_fallback\": true")
  }
}

# ─── Deployment: claude-gateway ───────────────────────────────────────────────

resource "kubernetes_deployment" "claude_gateway" {
  metadata {
    name      = "claude-gateway"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
    labels = {
      app     = "claude-gateway"
      version = local.gw_version
    }
  }

  spec {
    replicas = local.gw_replicas

    selector {
      match_labels = { app = "claude-gateway" }
    }

    template {
      metadata {
        labels = { app = "claude-gateway" }
      }

      spec {
        service_account_name            = kubernetes_service_account.claude_gateway.metadata[0].name
        automount_service_account_token = true

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000
          seccomp_profile { type = "RuntimeDefault" }
        }

        # nginx access-log sidecar: receives traffic on 8080, proxies to ttl-proxy on 8082.
        # Logs User-Agent + surface for Chat/Code/Cowork/CLI identification.
        # Traffic path: nginx(8080) → ttl-proxy(8082) → gateway(8081)
        container {
          name  = "nginx-access-log"
          image = "nginx:1.27-alpine"

          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }

          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-tmp"
            mount_path = "/var/cache/nginx"
          }
          volume_mount {
            name       = "nginx-run"
            mount_path = "/var/run"
          }

          resources {
            requests = { cpu = "50m",  memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }

          liveness_probe {
            tcp_socket { port = 8080 }
            initial_delay_seconds = 5
            period_seconds        = 15
          }

          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            run_as_user                = 101  # nginx user
            capabilities { drop = ["ALL"] }
          }
        }

        container {
          name    = "claude-gateway"
          image   = local.gateway_image
          command = ["claude", "gateway", "--config", "/etc/gateway/gateway.yaml"]

          # Gateway moves to 8081 — nginx on 8080 proxies to it
          port {
            name           = "gw-internal"
            container_port = 8081
            protocol       = "TCP"
          }

          env_from {
            secret_ref {
              name     = "bedrock-credentials"
              optional = true
            }
          }

          env {
            name  = "CLAUDE_GATEWAY_ALLOW_LOOPBACK"
            value = "1"
          }
          env {
            name  = "GATEWAY_JWT_SECRET"
            value = lookup(var.claude_gateway, "gateway_jwt_secret", "")
          }
          env {
            name  = "GATEWAY_POSTGRES_URL"
            value = local.pg_url
          }

          volume_mount {
            name       = "gateway-config"
            mount_path = "/etc/gateway"
            read_only  = true
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          resources {
            requests = { cpu = "250m", memory = "256Mi" }
            limits   = { cpu = "1", memory = "512Mi" }
          }

          liveness_probe {
            tcp_socket { port = 8081 }
            initial_delay_seconds = 15
            period_seconds        = 20
            failure_threshold     = 3
          }

          readiness_probe {
            tcp_socket { port = 8081 }
            initial_delay_seconds = 5
            period_seconds        = 10
            failure_threshold     = 2
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities { drop = ["ALL"] }
          }
        }

        # OTel collector sidecar — only deployed when monitoring_enabled = true.
        # Receives OTLP from the gateway process on loopback 127.0.0.1:4318 and ships
        # telemetry (spans, logs, metrics) to Loki via otlphttp. Also serves as the
        # OTLP endpoint for CLI clients — they send to the gateway public URL and the
        # gateway proxies internally to this sidecar. Without it, CLI telemetry and
        # the managed-policy OTEL env vars silently drop.
        dynamic "container" {
          for_each = local.monitoring_enabled ? [1] : []
          content {
            name    = "otel-collector"
            image   = "otel/opentelemetry-collector-contrib:0.103.0"
            command = ["/otelcol-contrib", "--config", "/etc/otelcol/otelcol.yaml"]

            port {
              name           = "otlp-grpc"
              container_port = 4317
            }
            port {
              name           = "otlp-http"
              container_port = 4318
            }

            volume_mount {
              name       = "otel-config"
              mount_path = "/etc/otelcol"
              read_only  = true
            }
            volume_mount {
              name       = "otel-tmp"
              mount_path = "/tmp"
            }

            resources {
              requests = { cpu = "50m", memory = "64Mi" }
              limits   = { cpu = "200m", memory = "256Mi" }
            }

            # kubelet http_get probes connect to pod IP — health_check binds 0.0.0.0 so the probe reaches it.
            # exec probe removed: otel-collector-contrib is distroless (no /bin/sh or wget).
            liveness_probe {
              http_get {
                path = "/"
                port = 13133
              }
              initial_delay_seconds = 10
              period_seconds        = 15
            }

            security_context {
              allow_privilege_escalation = false
              read_only_root_filesystem  = true
              run_as_non_root            = true
              capabilities { drop = ["ALL"] }
            }
          }
        }

        # TTL proxy sidecar — only deployed when ttl_proxy_enabled = true.
        # Strips cache_control.ttl from /v1/messages requests before they reach the
        # gateway. Required for Claude 3.x APAC Bedrock models which reject that field
        # with "Extra inputs not permitted". Claude 4.x global profiles do not have this
        # restriction — safe to disable if only 4.x models are in use.
        # Traffic path: nginx(8080) → ttl-proxy(8082) → gateway(8081).
        # When disabled, nginx routes directly to gateway(8081).
        dynamic "container" {
          for_each = local.ttl_proxy_enabled ? [1] : []
          content {
            name              = "ttl-proxy"
            image             = "python:3.12-alpine"
            image_pull_policy = "IfNotPresent"
            command           = ["python3", "-u", "/app/proxy.py"]

            volume_mount {
              name       = "ttl-proxy-script"
              mount_path = "/app"
            }

            resources {
              requests = { cpu = "50m",  memory = "64Mi" }
              limits   = { cpu = "200m", memory = "256Mi" }
            }

            readiness_probe {
              tcp_socket { port = 8082 }
              initial_delay_seconds = 5
              period_seconds        = 10
              failure_threshold     = 2
            }

            liveness_probe {
              tcp_socket { port = 8082 }
              initial_delay_seconds = 10
              period_seconds        = 15
              failure_threshold     = 3
            }

            security_context {
              allow_privilege_escalation = false
              run_as_non_root            = false  # python:alpine runs as root by default
              capabilities { drop = ["ALL"] }
            }
          }
        }

        volume {
          name = "nginx-config"
          config_map { name = kubernetes_config_map.nginx_access_log.metadata[0].name }
        }
        volume {
          name = "nginx-tmp"
          empty_dir {}
        }
        volume {
          name = "nginx-run"
          empty_dir {}
        }
        volume {
          name = "gateway-config"
          config_map { name = kubernetes_config_map.claude_gateway.metadata[0].name }
        }
        dynamic "volume" {
          for_each = local.monitoring_enabled ? [1] : []
          content {
            name = "otel-config"
            config_map { name = kubernetes_config_map.otel_collector[0].metadata[0].name }
          }
        }
        volume {
          name = "tmp"
          empty_dir {}
        }
        dynamic "volume" {
          for_each = local.monitoring_enabled ? [1] : []
          content {
            name = "otel-tmp"
            empty_dir {}
          }
        }
        dynamic "volume" {
          for_each = local.ttl_proxy_enabled ? [1] : []
          content {
            name = "ttl-proxy-script"
            config_map {
              name         = kubernetes_config_map.ttl_proxy_script.metadata[0].name
              default_mode = "0755"
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_config_map.nginx_access_log,
    kubernetes_config_map.ttl_proxy_script,
    kubernetes_config_map.claude_gateway,
    kubernetes_config_map.otel_collector,  # count resource — safe, Terraform resolves the list
    kubernetes_service_account.claude_gateway,
    kubernetes_deployment.postgres,
    kubernetes_deployment.loki,            # count resource
  ]
}

# ─── Service ──────────────────────────────────────────────────────────────────

resource "kubernetes_service" "claude_gateway" {
  metadata {
    name      = "claude-gateway"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }
  spec {
    selector = { app = "claude-gateway" }
    type     = "ClusterIP"
    port {
      name        = "http"
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

# ─── Ingress: ALB — Gateway (HTTPS :443 + HTTP :80) ──────────────────────────

resource "kubernetes_ingress_v1" "claude_gateway" {
  metadata {
    name      = "claude-gateway"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
    annotations = merge(
      {
        "kubernetes.io/ingress.class"                            = "alb"
        "alb.ingress.kubernetes.io/scheme"                       = "internet-facing"
        "alb.ingress.kubernetes.io/target-type"                  = "ip"
        "alb.ingress.kubernetes.io/listen-ports"                 = jsonencode([{ HTTPS = 443 }, { HTTP = 80 }])
        "alb.ingress.kubernetes.io/ssl-policy"                   = "ELBSecurityPolicy-TLS13-1-2-2021-06"
        "alb.ingress.kubernetes.io/load-balancer-attributes"     = "idle_timeout.timeout_seconds=300"
        "alb.ingress.kubernetes.io/subnets"                      = join(",", var.public_subnet_ids)
        "alb.ingress.kubernetes.io/group.name"                   = "${var.default["project"]}-${var.default["env"]}-claude"
        "alb.ingress.kubernetes.io/group.order"                  = "20"
        "alb.ingress.kubernetes.io/healthcheck-protocol"         = "HTTP"
        "alb.ingress.kubernetes.io/healthcheck-path"             = "/healthz"
        "alb.ingress.kubernetes.io/success-codes"                = "200"
        "alb.ingress.kubernetes.io/healthcheck-interval-seconds" = "60"
        "alb.ingress.kubernetes.io/healthcheck-timeout-seconds"  = "5"
        "alb.ingress.kubernetes.io/healthy-threshold-count"      = "2"
        "alb.ingress.kubernetes.io/unhealthy-threshold-count"    = "3"
      },
      {
        "alb.ingress.kubernetes.io/certificate-arn" = local.acm_cert_arn
      }
    )
  }

  spec {

    rule {
      host = local.gw_hostname
      http {
        dynamic "path" {
          for_each = local.monitoring_enabled ? [1] : []
          content {
            path      = "/grafana"
            path_type = "Prefix"
            backend {
              service {
                name = kubernetes_service.grafana[0].metadata[0].name
                port { number = 3000 }
              }
            }
          }
        }
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.claude_gateway.metadata[0].name
              port { number = 80 }
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_deployment.claude_gateway,
    kubernetes_deployment.grafana,  # count resource
  ]
}


# ─── ALB hostname (for DNS/output) ────────────────────────────────────────────

data "kubernetes_ingress_v1" "claude_gateway_lb" {
  metadata {
    name      = kubernetes_ingress_v1.claude_gateway.metadata[0].name
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }
  depends_on = [kubernetes_ingress_v1.claude_gateway]
}

locals {
  alb_hostname = try(
    data.kubernetes_ingress_v1.claude_gateway_lb.status[0].load_balancer[0].ingress[0].hostname,
    ""
  )
}

# ─── Route53 (optional — creates CNAME if private_zone_id is set) ────────────

resource "aws_route53_record" "claude_gateway" {
  count   = var.private_zone_id != "" && local.alb_hostname != "" ? 1 : 0
  zone_id = var.private_zone_id
  name    = local.gw_hostname
  type    = "CNAME"
  ttl     = 60
  records = [local.alb_hostname]
}

# ─── HPA ──────────────────────────────────────────────────────────────────────

resource "kubernetes_horizontal_pod_autoscaler_v2" "claude_gateway" {
  metadata {
    name      = "claude-gateway"
    namespace = kubernetes_namespace.claude_system.metadata[0].name
  }

  spec {
    min_replicas = local.gw_replicas
    max_replicas = local.gw_replicas * 3

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.claude_gateway.metadata[0].name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
  }
}
