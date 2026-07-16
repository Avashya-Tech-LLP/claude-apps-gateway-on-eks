variable "default" {}

variable "vpc_id" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "lbc_role_arn" {
  type = string
}

variable "karpenter_role_arn" {
  type = string
}

variable "karpenter_interruption_queue_name" {
  type = string
}

variable "node_role_name" {
  type = string
}

variable "enable_karpenter" {
  description = "Deploy Karpenter and its NodePool/EC2NodeClass. Set false for Dev."
  type        = bool
  default     = true
}
