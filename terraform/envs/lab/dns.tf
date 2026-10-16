# Optional public DNS and ACM certificate for the application edge. The lab consumes an existing
# public hosted zone; it never registers a domain or creates the zone. ExternalDNS owns only the
# application A record and its prefixed TXT ownership record in that one zone.

locals {
  dns_enabled             = var.app_domain_name != ""
  external_dns_txt_record = "a-_external-dns-${var.app_domain_name}"
  route53_public_zone_arn = local.dns_enabled ? "arn:${data.aws_partition.current.partition}:route53:::hostedzone/${var.route53_public_zone_id}" : ""
  external_dns_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ExternalDnsFromThisServiceAccount"
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = {
          "aws:SourceAccount"                         = data.aws_caller_identity.current.account_id
          "aws:RequestTag/kubernetes-namespace"       = "kube-system"
          "aws:RequestTag/kubernetes-service-account" = "external-dns"
        }
        ArnEquals = { "aws:SourceArn" = module.eks.cluster_arn }
      }
    }]
  })
}

data "aws_route53_zone" "public" {
  count = local.dns_enabled ? 1 : 0

  zone_id      = var.route53_public_zone_id
  private_zone = false
}

resource "aws_acm_certificate" "app" {
  count = local.dns_enabled ? 1 : 0

  domain_name       = var.app_domain_name
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"
  options {
    certificate_transparency_logging_preference = "ENABLED"
  }
  tags = merge(local.default_tags, { Name = "${local.name}-app-edge" })

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = endswith("${var.app_domain_name}.", data.aws_route53_zone.public[0].name)
      error_message = "app_domain_name must be inside the selected public Route53 hosted zone."
    }
  }
}

resource "aws_route53_record" "app_certificate_validation" {
  for_each = local.dns_enabled ? { app = var.app_domain_name } : {}

  zone_id         = data.aws_route53_zone.public[0].zone_id
  name            = one(aws_acm_certificate.app[0].domain_validation_options).resource_record_name
  type            = one(aws_acm_certificate.app[0].domain_validation_options).resource_record_type
  records         = [one(aws_acm_certificate.app[0].domain_validation_options).resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "app" {
  count = local.dns_enabled ? 1 : 0

  certificate_arn         = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [aws_route53_record.app_certificate_validation["app"].fqdn]
}

resource "aws_iam_role" "external_dns" {
  count = local.dns_enabled ? 1 : 0

  name                 = "${local.name}-external-dns"
  description          = "ExternalDNS for the ${var.app_domain_name} record in one Route53 zone."
  assume_role_policy   = local.external_dns_trust_policy
  permissions_boundary = local.permissions_boundary_arn
}

resource "aws_iam_role_policy" "external_dns" {
  count = local.dns_enabled ? 1 : 0

  name = "manage-app-dns-records"
  role = aws_iam_role.external_dns[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DiscoverHostedZone"
        Effect   = "Allow"
        Action   = "route53:ListHostedZones"
        Resource = "*"
      },
      {
        Sid      = "ReadOnlyThisHostedZone"
        Effect   = "Allow"
        Action   = "route53:ListResourceRecordSets"
        Resource = local.route53_public_zone_arn
      },
      {
        Sid      = "ChangeOnlyTheAppAliasAndOwnershipRecord"
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = local.route53_public_zone_arn
        Condition = {
          "ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = [var.app_domain_name, local.external_dns_txt_record]
            "route53:ChangeResourceRecordSetsRecordTypes"           = ["A", "TXT"]
            "route53:ChangeResourceRecordSetsActions"               = ["CREATE", "UPSERT", "DELETE"]
          }
        }
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "external_dns" {
  count = local.dns_enabled ? 1 : 0

  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns[0].arn
}
