output "claude_gateway_role_arn" {
  description = "IRSA role ARN for the claude-gateway pod"
  value       = aws_iam_role.claude_gateway.arn
}

output "ecr_repository_url" {
  description = "ECR repository URL for the claude-gateway image"
  value       = aws_ecr_repository.claude_gateway.repository_url
}

output "claude_system_namespace" {
  description = "Kubernetes namespace where claude-gateway runs"
  value       = kubernetes_namespace.claude_system.metadata[0].name
}

output "alb_hostname" {
  description = "ALB DNS hostname assigned by AWS (available after ALB is provisioned)"
  value       = local.alb_hostname
}

output "gateway_hostname" {
  description = "Internal hostname of the claude-gateway ALB"
  value       = local.gw_hostname
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN used by the ALB listener"
  value       = local.acm_cert_arn
}

