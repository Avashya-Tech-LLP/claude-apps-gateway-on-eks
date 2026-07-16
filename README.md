# Claude Apps Gateway on EKS

Deploy Anthropic's [Claude Apps Gateway](https://docs.anthropic.com/en/docs/claude-code/claude-apps-gateway) on AWS EKS using Terraform. Gives your organization a private, enterprise-managed inference gateway so that Claude Code CLI and Claude Desktop route through your infrastructure instead of calling Anthropic directly.

**References:**
- [Introducing Claude Apps Gateway for AWS](https://aws.amazon.com/blogs/machine-learning/introducing-claude-apps-gateway-for-aws/) — AWS blog overview
- [Claude Apps Gateway documentation](https://docs.anthropic.com/en/docs/claude-code/claude-apps-gateway) — official Anthropic docs
- [Claude Code CLI documentation](https://docs.anthropic.com/en/docs/claude-code) — Anthropic docs

---

## What this deploys

```
┌──────────────────────────────┐
│  Developer Computer          │
│  Claude Code CLI ────────────┼──────┐
│  Claude Desktop  ────────────┼──────┤ HTTPS :443 (ACM cert)
└──────────────────────────────┘      │
                                      ▼
                            ┌─────────────────────┐
                            │      AWS ALB        │
                            │  internet-facing    │
                            └──────────┬──────────┘
                                       │
              ┌────────────────────────▼────────────────────────┐
              │       EKS Cluster  ·  (claude-system ns)        │
              │                                                 │
              │  ┌──────────────────────────────────────────┐   │
              │  │  Gateway Pod                             │   │
              │  │  nginx          :8080                    │   │
              │  │  ttl-proxy      :8082  [optional]        │   │
              │  │  gateway        :8081                    │   │
              │  │  otel-collector :4318  [optional]        │   │
              │  └──────────────────────────────────────────┘   │
              │                                                 │
              │         Postgres     Loki     Grafana           │
              └────────────────────────┬────────────────────────┘
                                       │ IRSA
                                       ▼
                                  AWS Bedrock
```

**Key design decisions:**
- Any OIDC provider (JumpCloud, Okta, Keycloak, etc.) for per-user identity — no shared credentials
- IRSA for Bedrock access — the gateway ServiceAccount is annotated with the IRSA role ARN
- DNS-validated ACM certificate on your own domain — no self-signed certs in production
- Feature flags for optional components: `monitoring_enabled`, `ttl_proxy_enabled`
- ttl-proxy strips `cache_control.ttl` from requests to Claude 3.x APAC Bedrock models (which reject that field); safe to disable for Claude 4.x global profiles
- OTel sidecar binds `0.0.0.0` for health probes (distroless image — no shell); ttl-proxy binds `0.0.0.0` for the same reason (kubelet probes connect to pod IP, not loopback)

---

## Repository structure

```
.
├── Terraform/
│   ├── environments/dev/         # tfvars template (copy and fill in your values)
│   ├── modules/
│   │   ├── claude-gateway/       # Gateway pod, Postgres, Loki, Grafana, ALB, ACM cert
│   │   ├── eks/                  # EKS cluster + managed node group
│   │   ├── eks-addons/           # AWS Load Balancer Controller, EBS CSI driver
│   │   ├── networking/           # VPC, subnets, NAT GW, VPC endpoints
│   │   └── route53/              # Optional: Route53 hosted zone + CNAME
│   ├── main.tf
│   ├── providers.tf
│   └── variables.tf
│
├── docker/claude-gateway/
│   ├── Dockerfile                # Wraps @anthropic-ai/claude-code npm package
│   └── build-and-push.sh         # Build + push to ECR (account and region auto-detected)
│
├── scripts/
│   ├── setup-claude-desktop.sh   # Configure Claude Desktop → gateway with OIDC SSO
│   ├── switch-claude-code-to-gateway.sh
│   ├── switch-claude-code-to-bedrock.sh
│   ├── backup-claude-config.sh
│   └── restore-claude-config.sh
│
└── docs/
    ├── ARCHITECTURE.md           # Architecture deep-dive
    └── RUNBOOK.md                # Deployment, operations, and troubleshooting guide
```

---

## Prerequisites

- AWS CLI v2, authenticated
- `kubectl` >= 1.28
- `terraform` >= 1.6
- `docker` (for ECR image builds)
- An OIDC identity provider (JumpCloud, Okta, Keycloak, etc.) with a registered app

---

## Quick start

### 1. Build and push the gateway image

```bash
cd docker/claude-gateway
./build-and-push.sh          # auto-detects account ID and region
```

### 2. Configure tfvars

Copy `Terraform/environments/dev/terraform.tfvars.example` and fill in your values:

```hcl
default = {
  project = "myorg"
  env     = "dev"
  region  = "us-east-1"
}

claude_gateway = {
  gateway_version  = "2.1.195"
  gateway_replicas = 1

  # Your domain (e.g. claude.yourcompany.com) — create a Route53 CNAME to the ALB after apply.
  gateway_hostname = "claude.yourcompany.com"

  # ACM certificate ARN for your domain (must be DNS-validated in the same region).
  acm_certificate_arn = "arn:aws:acm:<region>:<account-id>:certificate/<id>"

  bedrock_region    = "us-east-1"   # or ap-south-1, eu-west-1, etc.
  session_ttl_hours = 168

  # OIDC identity provider (JumpCloud, Okta, Keycloak, etc.)
  oidc_client_id     = "REPLACE_WITH_OIDC_CLIENT_ID"
  oidc_client_secret = "REPLACE_WITH_OIDC_CLIENT_SECRET"
  allowed_email_domain    = "yourcompany.com"

  grafana_admin_password = "REPLACE_WITH_STRONG_PASSWORD"  # required only if monitoring_enabled = true

  # Feature flags
  monitoring_enabled = true  # Loki, Grafana, log-forwarder, OTel sidecar
  ttl_proxy_enabled  = true  # required for Claude 3.x APAC Bedrock models
}
```

### 3. Apply

```bash
cd Terraform
terraform init
terraform apply -var-file="environments/dev/terraform.tfvars"
```

After apply, create a Route53 CNAME pointing your domain to the ALB:

```bash
terraform output gateway_hostname
# e.g. k8s-myorg-xxx.us-east-1.elb.amazonaws.com
# Create: claude.yourcompany.com → <ALB hostname>
```

---

## Client setup

### Claude Desktop (Chat / Code / Cowork)

```bash
# Edit GATEWAY_URL and OIDC values at the top of the script first
bash scripts/setup-claude-desktop.sh
```

The script writes the managed plist with `inferenceGatewayOidc` for SSO. On first launch Claude opens a browser to your OIDC provider — no manual certificate trust needed when using a valid ACM cert on your own domain.

### Claude Code CLI

```bash
./scripts/switch-claude-code-to-gateway.sh
claude /login    # browser opens to your OIDC provider
```

See [docs/RUNBOOK.md](docs/RUNBOOK.md) for full details.

---

## Feature flags

| Flag | Default | Effect when false |
|---|---|---|
| `monitoring_enabled` | `true` | Skips Loki, Grafana, log-forwarder, OTel sidecar |
| `ttl_proxy_enabled` | `true` | Removes the ttl-proxy hop (safe when only Claude 4.x global profiles are used) |

---

## Documentation

| Doc | Description |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Architecture deep-dive: container roles, surface detection, logging stack, security model |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | Deployment walkthrough, client setup, day-2 ops, troubleshooting |

---

## Destroy

```bash
kubectl delete ingress claude-gateway -n claude-system
sleep 60   # wait for ALB deprovisioning
kubectl delete pvc --all -n claude-system
cd Terraform && terraform destroy -var-file="environments/dev/terraform.tfvars"
```
