# Claude Apps Gateway on AWS EKS — Architecture

**References:**
- [Introducing Claude Apps Gateway for AWS](https://aws.amazon.com/blogs/machine-learning/introducing-claude-apps-gateway-for-aws/)
- [Claude Apps Gateway documentation](https://docs.anthropic.com/en/docs/claude-code/claude-apps-gateway)

---

## Table of Contents

1. [What This Deploys](#1-what-this-deploys)
2. [High-Level Architecture](#2-high-level-architecture)
3. [Network Design](#3-network-design)
4. [EKS Cluster & Workloads](#4-eks-cluster--workloads)
5. [Authentication & Session Flow](#5-authentication--session-flow)
6. [ALB Routing Rules](#6-alb-routing-rules)
7. [Bedrock Model Routing](#7-bedrock-model-routing)
8. [Logging Stack](#8-logging-stack)
9. [Security Model](#9-security-model)
10. [Terraform Module Dependency Order](#10-terraform-module-dependency-order)

---

## 1. What This Deploys

A private, enterprise-managed inference gateway. Claude Code CLI and Claude Desktop route all inference through an EKS-hosted Claude Apps Gateway instead of calling Anthropic directly. The gateway enforces OIDC authentication, logs every request with surface detection, and proxies to AWS Bedrock.

```
Developer Mac
  Claude Code CLI  ─────────────────────────────────────────────┐
  Claude Desktop   ─────────────────────────────────────────────┤
                                                                 │ HTTPS :443
                                                           AWS ALB
                                                          (internet-facing)
                                                                 │
                                                    ┌────────────┴────────────┐
                                                    │       EKS Cluster       │
                                                    │     claude-system ns    │
                                                    │                         │
                                              ┌─────┴──────────────────────┐  │
                                              │  Gateway Pod (2–4 ctrs)    │  │
                                              │  nginx(8080)               │  │
                                              │  → ttl-proxy(8082) [opt]   │  │
                                              │  → gateway(8081)           │  │
                                              │  → otel-sidecar [opt]  ────┼──┤
                                              └──────────────────────┬─────┘  │
                                                     │ OTLP [opt]   │        │
                                              ┌──────▼──────┐ ┌──────────┐   │
                                              │    Loki     │ │Postgres  │   │
                                              └──────┬──────┘ └──────────┘   │
                                              ┌──────▼──────┐                │
                                              │   Grafana   │◄── /grafana    │
                                              └─────────────┘                │
                                                    └────────────────────────┘
                                                                 │
                                                        AWS Bedrock
                                                          (via IRSA)
```

---

## 2. High-Level Architecture

```
Internet
   │
   ▼
AWS ALB (internet-facing)
  :443 HTTPS — ACM certificate (DNS-validated, attached via `acm_certificate_arn`)
   │
   ├── /grafana  → Grafana :3000              [monitoring_enabled only]
   └── /         → Gateway nginx :8080
          │
          ├── ttl-proxy :8082                 [ttl_proxy_enabled only]
          ├── gateway :8081
          ├── OIDC token validation → OIDC Provider (JWKS endpoint)
          ├── Session store         → Postgres :5432
          └── Inference             → AWS Bedrock
                                       global.anthropic.* inference profiles
```

---

## 3. Network Design

```
VPC: <your-cidr>
│
├── AZ 1
│   ├── Public subnet   ← ALB nodes, NAT GW
│   └── Private subnet  ← EKS worker nodes
│
└── AZ 2
    ├── Public subnet   ← ALB nodes
    └── Private subnet  ← EKS worker nodes
```

**Traffic flows:**

| Flow | Path |
|---|---|
| Developer → gateway | Internet → ALB (public subnet) → pod (private subnet) |
| Pod → Bedrock | Pod → NAT GW → IGW → Bedrock regional endpoint |
| Pod → ECR | Pod → Interface VPC Endpoint (stays in AWS network) |

For dev/test a single NAT GW is sufficient. For production, use one NAT GW per AZ to avoid single-AZ dependency.

---

## 4. EKS Cluster & Workloads

**Pods in `claude-system`:**

| Pod | Image | Feature flag | Purpose |
|---|---|---|---|
| `claude-gateway` | ECR `<project>-claude-gateway:<version>` | always on | API proxy — JWT validation, Bedrock routing, session management |
| `postgres` | `postgres:16-alpine` | always on | Gateway session store (user sessions, token cache) |
| `loki` | `grafana/loki:3.1.0` | `monitoring_enabled` | Log storage with configurable retention |
| `grafana` | `grafana/grafana:11.1.0` | `monitoring_enabled` | Usage dashboards — requests per user, surface breakdown, latency, error rate |
| `log-forwarder` | `python:3.12-alpine` | `monitoring_enabled` | Ships gateway + nginx container logs to Loki every 30s via K8S API |

### Gateway pod containers (2–4 depending on flags)

| Container | Port | Feature flag | Purpose |
|---|---|---|---|
| `nginx-access-log` | `:8080` (public) | always on | First hop for all traffic. Logs a JSON line per request with `surface` (chat/code/cowork/cli), `user_agent`, `request_id`, `upstream_ms`. Two-stage nginx `map` — first classifies by User-Agent; second overrides using request body tool names to separate Chat vs Cowork vs CLI (they share the same User-Agent). Feeds `{job="gateway-access"}` Loki stream. |
| `claude-gateway` | `:8081` (loopback) | always on | Core process. Validates OIDC JWT via JWKS, writes/reads sessions in Postgres, proxies inference to Bedrock via IRSA. Emits inference events as OTLP to the OTel sidecar on `127.0.0.1:4318`. |
| `otel-collector` | `:4317/:4318` (loopback) | `monitoring_enabled` | Receives OTLP from the gateway process and from CLI clients (gateway acts as OTLP proxy). Exports to Loki via `otlphttp`. Binds health_check on `0.0.0.0:13133` — required because the image is distroless (no shell) so kubelet liveness uses `http_get`, which connects to the pod IP not loopback. |
| `ttl-proxy` | `:8082` (loopback) | `ttl_proxy_enabled` | Strips `cache_control.ttl` from `/v1/messages` bodies. Claude 3.x APAC Bedrock models reject `ttl` ("Extra inputs not permitted") — Claude 4.x global profiles do not. Binds `0.0.0.0:8082` so kubelet TCP socket probes can reach it via pod IP. Safe to disable when only Claude 4.x global profiles are in use. |

**Traffic path (both flags on):** `ALB → nginx:8080 → ttl-proxy:8082 → gateway:8081 → Bedrock`  
**Traffic path (`ttl_proxy_enabled = false`):** `ALB → nginx:8080 → gateway:8081 → Bedrock`

### TLS certificate

The ALB HTTPS listener attaches an ACM certificate provided via `acm_certificate_arn` in tfvars. This should be a DNS-validated certificate issued for your domain (e.g. `claude.yourcompany.com`). After `terraform apply`, create a Route53 CNAME from your domain to the ALB hostname.

---

## 5. Authentication & Session Flow

### Claude Desktop

```
setup-desktop.sh
  1. Writes /Library/Managed Preferences/com.anthropic.claudefordesktop.plist:
       inferenceProvider:       gateway
       inferenceGatewayBaseUrl: https://<gateway-hostname>
       inferenceGatewayOidc:    { clientId, issuer, authorizationUrl, tokenUrl,
                                  bearerTokenType: access_token,
                                  scopes: openid email profile, appendOfflineAccess: true }
       chatTabEnabled:          true
  3. Relaunches Claude Desktop

First launch: browser opens to OIDC provider → user logs in with corporate credentials
Subsequent launches: silent token refresh via OIDC (no re-run needed)
```

### Claude Code CLI

```bash
claude /login
# Browser opens to OIDC provider
# CLI stores session token and re-authenticates on expiry
```

---

## 6. ALB Routing Rules

Two ingress resources share one ALB via `group.name`:

**HTTPS :443 ingress (`claude-gateway`):**

| Path | Backend | Notes |
|---|---|---|
| `/grafana` | Grafana :3000 | Only present when `monitoring_enabled = true` |
| `/` | Gateway nginx :8080 | Catch-all |

---

## 7. Bedrock Model Routing

All models use **global** cross-region inference profiles. APAC-specific profiles can be added as aliases for lower latency — but they may go into legacy suspension when unused for extended periods; global profiles do not have this problem.

| Gateway model ID | Bedrock upstream |
|---|---|
| `claude-sonnet-4-6` | `global.anthropic.claude-sonnet-4-6` |
| `claude-opus-4-8` | `global.anthropic.claude-opus-4-8` |
| `claude-sonnet-5` | `global.anthropic.claude-sonnet-5` |
| `claude-haiku-4-5-20251001` | `global.anthropic.claude-haiku-4-5-20251001-v1:0` |

`auto_include_builtin_models: true` — the gateway also exposes its builtin model list alongside the above aliases.

---

## 8. Logging Stack

```
ALB :443
  │
  ▼
nginx sidecar :8080 (container: nginx-access-log)
  │  Logs: {ts, request_id, surface, user_agent, status, upstream_ms}
  │  surface = chat | code | cowork | cli | desktop-webview | healthcheck | unknown
  │           ← User-Agent + request body tool signals (two-stage nginx map)
  │
  ▼ proxy_pass 127.0.0.1:8081 (or 8082 if ttl_proxy_enabled)
Gateway :8081 (container: claude-gateway)
  │  Logs: {evt:inference, email, model, status, ms, request_id}
  │
  ├──→ OTLP 127.0.0.1:4318 → OTel Collector sidecar
  │
  ▼
log-forwarder pod (reads both containers via K8S API every 30s)
  │  Stream 1: {job=claude-gateway}   inference events
  │  Stream 2: {job=gateway-access}   nginx access log
  │
  ▼
Loki :3100
  │
  ▼
Grafana :3000  https://<gateway-hostname>/grafana
```

**Two queryable Loki streams:**

| Stream | Key fields | Use |
|---|---|---|
| `{job="claude-gateway"}` | `email`, `model`, `status`, `ms`, `request_id` | Inference analytics |
| `{job="gateway-access"}` | `surface`, `user_agent`, `request_id`, `upstream_ms` | Chat/Code/Cowork/CLI breakdown |

Join by `request_id` to correlate surface with model/user/latency.

**Surface detection** — two-stage nginx `map` block:

| User-Agent pattern | Body signal | Surface |
|---|---|---|
| `Claude for Desktop/X (chat)` | — | `chat` |
| `Claude for Desktop/X (code)` | — | `code` |
| `Claude for Desktop/X (cowork)` | — | `cowork` |
| `claude-cli … claude-desktop-3p` | — | `code` (Desktop Code surface) |
| `claude-cli … local-agent` | has native `Bash` tool | `cli` (Claude Code CLI) |
| `claude-cli … local-agent` | has `Agent`/`TaskCreate` tools | `cowork` |
| `claude-cli … local-agent` | neither | `chat` |
| `Mozilla … Electron` | — | `desktop-webview` |

`chat` and `cowork` share identical User-Agents (`local-agent`) — distinguished by whether the request body includes agentic tools. Claude Code CLI also uses `local-agent` but sends a native `Bash` tool (not `mcp__workspace__bash`), which uniquely identifies it.

---

## 9. Security Model

```
Layer 1: VPC
  ├── Nodes in private subnets (no direct internet ingress)
  └── ALB is the only entry point (public subnets)

Layer 2: ALB security group
  └── Allows 443 inbound from 0.0.0.0/0

Layer 3: OIDC auth
  └── Every inference request requires a valid JWT from your OIDC provider
      (validated via JWKS — gateway acts as resource server)

Layer 4: Pod security
  └── claude-gateway container: no root, no privilege escalation,
      read-only root fs, all capabilities dropped

Layer 5: Bedrock credentials scope
  └── IRSA role (or IAM user) has only bedrock:Invoke* + bedrock:List*
      No other AWS access
```

---

## 10. Terraform Module Dependency Order

```
modules/networking        VPC, subnets, NAT GW, VPC endpoints
      │
      ▼
modules/eks               EKS cluster, managed node group, OIDC, IRSA
      │
      ▼
modules/eks-addons        AWS Load Balancer Controller, EBS CSI driver
      │
      ▼
modules/claude-gateway    Namespace, StorageClass, Postgres,
                          Gateway (+ optional OTel/ttl-proxy sidecars),
                          Loki, Grafana, ALB ingress (attaches ACM cert)
```

All modules are applied in one `terraform apply`. The `modules/route53` module is optional — disable it if you are not using a custom domain.
