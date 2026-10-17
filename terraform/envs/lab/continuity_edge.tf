# ACM certificates are regional. AWS reuses the DNS validation token across Regions in one account,
# so the existing validation record authorizes the secondary certificate without another record owner.
resource "aws_acm_certificate" "app_dr" {
  count    = var.db_profile == "dr" && local.dns_enabled ? 1 : 0
  provider = aws.dr

  domain_name       = var.app_domain_name
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"
  options {
    certificate_transparency_logging_preference = "ENABLED"
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "app_dr" {
  count    = var.db_profile == "dr" && local.dns_enabled ? 1 : 0
  provider = aws.dr

  certificate_arn         = aws_acm_certificate.app_dr[0].arn
  validation_record_fqdns = [aws_route53_record.app_certificate_validation["app"].fqdn]
}

resource "aws_iam_role" "external_dns_dr" {
  count                = var.db_profile == "dr" && local.dns_enabled ? 1 : 0
  name                 = "${local.name}-dr-external-dns"
  description          = "DNS failover identity of the secondary cluster; one app record in one zone."
  permissions_boundary = local.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = {
          "aws:SourceAccount"                         = data.aws_caller_identity.current.account_id
          "aws:RequestTag/kubernetes-namespace"       = "kube-system"
          "aws:RequestTag/kubernetes-service-account" = "external-dns"
        }
        ArnEquals = { "aws:SourceArn" = module.eks_dr[0].cluster_arn }
      }
    }]
  })
}

resource "aws_iam_role_policy" "external_dns_dr" {
  count  = var.db_profile == "dr" && local.dns_enabled ? 1 : 0
  name   = "manage-app-dns-records"
  role   = aws_iam_role.external_dns_dr[0].id
  policy = aws_iam_role_policy.external_dns[0].policy
}

resource "aws_eks_pod_identity_association" "external_dns_dr" {
  count           = var.db_profile == "dr" && local.dns_enabled ? 1 : 0
  provider        = aws.dr
  cluster_name    = module.eks_dr[0].cluster_name
  namespace       = "kube-system"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns_dr[0].arn
}
