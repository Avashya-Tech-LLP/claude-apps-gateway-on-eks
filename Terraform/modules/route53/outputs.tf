output "acm_certificate_arn" {
  description = "ACM certificate ARN"
  value       = aws_acm_certificate.main.arn
}

output "private_zone_id" {
  description = "Route53 private hosted zone ID"
  value       = aws_route53_zone.private.zone_id
}

output "public_zone_id" {
  description = "Route53 public hosted zone ID (empty if not created)"
  value       = length(aws_route53_zone.public) > 0 ? aws_route53_zone.public[0].zone_id : null
}

output "name_servers" {
  description = "Name servers for public zone (delegate from registrar)"
  value       = length(aws_route53_zone.public) > 0 ? aws_route53_zone.public[0].name_servers : []
}
