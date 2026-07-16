variable "default" {}
variable "route53" {}

variable "vpc_id" {
  description = "VPC ID for private hosted zone association"
  type        = string
}
