# ─── Public Hosted Zone ───────────────────────────────────────────────────────

resource "aws_route53_zone" "public" {
  count = lookup(var.route53, "create_public_zone", false) ? 1 : 0
  name  = var.route53["domain_name"]

  tags = {
    Name = "${var.default["env"]}-${var.default["project"]}-public-zone"
  }
}

# ─── Private Hosted Zone ──────────────────────────────────────────────────────

resource "aws_route53_zone" "private" {
  name = lookup(var.route53, "private_zone_name", "internal.${var.route53["domain_name"]}")

  vpc {
    vpc_id = var.vpc_id
  }

  tags = {
    Name = "${var.default["env"]}-${var.default["project"]}-private-zone"
  }
}

# ─── ACM Certificate ──────────────────────────────────────────────────────────

resource "aws_acm_certificate" "main" {
  domain_name               = var.route53["domain_name"]
  subject_alternative_names = lookup(var.route53, "san_names", ["*.${var.route53["domain_name"]}"])
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.default["env"]}-${var.default["project"]}-acm"
  }
}

# ─── DNS Validation Records (in public zone) ──────────────────────────────────

resource "aws_route53_record" "cert_validation" {
  for_each = lookup(var.route53, "create_public_zone", false) ? {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.public[0].zone_id
}

resource "aws_acm_certificate_validation" "main" {
  count = lookup(var.route53, "create_public_zone", false) ? 1 : 0

  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}
