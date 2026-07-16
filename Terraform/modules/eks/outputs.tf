output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.cluster.name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = aws_eks_cluster.cluster.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate"
  value       = aws_eks_cluster.cluster.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = aws_security_group.cluster.id
}

output "node_security_group_id" {
  description = "Security group ID for EKS nodes"
  value       = aws_security_group.nodes.id
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider for IRSA"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "URL of the OIDC provider"
  value       = aws_iam_openid_connect_provider.eks.url
}

output "karpenter_interruption_queue_name" {
  description = "SQS queue name for Karpenter interruption handling"
  value       = var.enable_karpenter ? aws_sqs_queue.karpenter_interruption[0].name : ""
}

output "karpenter_role_arn" {
  description = "IAM role ARN for Karpenter"
  value       = var.enable_karpenter ? aws_iam_role.karpenter[0].arn : ""
}

output "lbc_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller"
  value       = aws_iam_role.lbc.arn
}

output "node_role_name" {
  description = "IAM role name for EKS nodes (used by Karpenter EC2NodeClass)"
  value       = aws_iam_role.node_group.name
}

output "ebs_csi_role_arn" {
  description = "IRSA role ARN for the EBS CSI driver"
  value       = aws_iam_role.ebs_csi.arn
}
