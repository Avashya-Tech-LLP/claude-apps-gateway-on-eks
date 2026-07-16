variable "default" {}

variable "eks" {}

variable "vpc_id" {
  description = "VPC ID for EKS cluster"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EKS nodes and control plane"
  type        = list(string)
}

variable "enable_karpenter" {
  description = "Create Karpenter IAM, SQS, and EventBridge resources"
  type        = bool
  default     = false
}
