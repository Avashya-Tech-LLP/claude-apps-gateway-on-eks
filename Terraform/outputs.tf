# VPC
output "vpc_id" {
  value = module.networking.vpc_id
}
output "private_subnets" {
  value = module.networking.private_subnets
}

# EKS
output "eks_cluster_name" {
  value = module.eks.cluster_name
}
output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

# ACM certificate
output "acm_certificate_arn" {
  value = module.claude_gateway.acm_certificate_arn
}

# Claude Apps Gateway
output "claude_gateway_role_arn" {
  value = module.claude_gateway.claude_gateway_role_arn
}
output "gateway_hostname" {
  value = module.claude_gateway.gateway_hostname
}
output "alb_hostname" {
  value = module.claude_gateway.alb_hostname
}
output "ecr_repository_url" {
  value = module.claude_gateway.ecr_repository_url
}
