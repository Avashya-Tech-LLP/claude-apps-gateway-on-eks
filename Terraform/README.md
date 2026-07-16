# Terraform — Claude Apps Gateway on EKS

**State:** local (`terraform.tfstate`) — migrate to S3 backend for production.

---

## Directory Structure

```
Terraform/
├── backend.tf                        # Local state backend
├── providers.tf                      # AWS, Kubernetes, Helm, kubectl, TLS providers
├── main.tf                           # Root module — wires all child modules
├── variables.tf                      # Root variable declarations
├── outputs.tf                        # Outputs: VPC ID, EKS cluster, ALB hostname, cert PEM, ECR URL
│
├── environments/
│   └── dev/
│       └── terraform.tfvars          # Your environment config values (copy from .example)
│
└── modules/
    ├── networking/                   # VPC, public/private subnets, NAT GW, route tables
    ├── eks/                          # EKS cluster, managed node group, OIDC, IRSA
    ├── eks-addons/                   # Helm: ALB controller, EBS CSI, CoreDNS, metrics-server
    ├── claude-gateway/               # Gateway deployment, Postgres, ALB ingress, ACM cert
    └── route53/                      # Route53 + ACM (optional — enable when custom domain available)
```

---

## Module Dependency Order

```
networking
    └── eks
            └── eks-addons
                        └── claude-gateway
```

---

## Prerequisites

```bash
terraform --version  # >= 1.6
aws --version        # AWS CLI v2, authenticated
kubectl version      # >= 1.28

aws eks update-kubeconfig --name <cluster-name> --region <region>
```

---

## Usage

All commands run from the `Terraform/` directory.

```bash
terraform init
terraform plan -var-file=environments/dev/terraform.tfvars
terraform apply -var-file=environments/dev/terraform.tfvars
```

### Key outputs after apply

```bash
terraform output -raw gateway_hostname    # ALB DNS — fill in tfvars for second apply
terraform output -raw cert_pem            # self-signed cert PEM
terraform output -raw acm_certificate_arn
terraform output -raw ecr_repository_url
```

### Targeted apply (common operations)

```bash
# Gateway deployment only (after config changes)
terraform apply -var-file=environments/dev/terraform.tfvars \
  -target=module.claude_gateway.kubernetes_deployment.claude_gateway

# ALB ingress only (after cert or annotation changes)
terraform apply -var-file=environments/dev/terraform.tfvars \
  -target=module.claude_gateway.kubernetes_ingress_v1.claude_gateway

# Rotate self-signed TLS cert
terraform taint module.claude_gateway.tls_private_key.claude_gateway
terraform apply -var-file=environments/dev/terraform.tfvars \
  -target=module.claude_gateway.tls_private_key.claude_gateway \
  -target=module.claude_gateway.tls_self_signed_cert.claude_gateway \
  -target=module.claude_gateway.aws_acm_certificate.claude_gateway
```

---

## Module: claude-gateway

| Resource | Details |
|---|---|
| ECR repository | `<project>-claude-gateway` — stores the custom gateway image |
| Namespace | `claude-system` |
| IRSA role | `<env>-<project>-claude-gateway-irsa` — Bedrock invoke permissions |
| Self-signed cert | CN=`claude-gateway`, SAN=`<alb_hostname>`, 1-year validity |
| ACM certificate | Imported from self-signed cert |
| Postgres deployment | Session store for the gateway, 10Gi gp3 PVC |
| Gateway deployment | `@anthropic-ai/claude-code:<version>` |
| ALB ingress | Internet-facing, HTTPS :443 |

---

## Two-pass bootstrap

The ALB hostname is assigned by AWS on first apply. After getting it:

```bash
terraform output -raw gateway_hostname
```

Use this value for the Route53 CNAME pointing your domain at the ALB. `gateway_public_url` is derived automatically from `gateway_hostname` — no need to set it separately.

---

## Destroy

```bash
# Delete ALB ingress first (triggers ALB deprovisioning — wait ~60s)
kubectl delete ingress claude-gateway -n claude-system
sleep 60

# Delete PVCs
kubectl delete pvc postgres-data loki-data grafana-data -n claude-system 2>/dev/null || true

# Destroy all Terraform-managed resources
terraform destroy -var-file=environments/dev/terraform.tfvars
```
