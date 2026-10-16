# Optional Route53 + ACM and the narrowly scoped ExternalDNS Pod Identity role. All AWS provider
# interactions below use shared mocks; this does not contact an AWS account or emit a real certificate.

mock_provider "aws" {
  source = "../../tests/mocks"
}

variables {
  github_owner                 = "maringelix"
  endpoint_public_access_cidrs = ["203.0.113.10/32"]
  cluster_admin_principal_arns = ["arn:aws:iam::123456789012:role/tx01v2-gha-apply"]
  app_deployer_principal_arns  = ["arn:aws:iam::123456789012:role/dx01v2-gha-deploy"]
}

run "dns_is_disabled_without_domain_inputs" {
  command = apply

  assert {
    condition     = output.app_domain_name == "disabled" && output.app_certificate_arn == "disabled" && output.external_dns_role_arn == "disabled"
    error_message = "The low-cost profile must not create DNS, certificate or ExternalDNS resources without an explicit domain and hosted zone."
  }

  assert {
    condition = alltrue([
      for p in aws_ssm_parameter.contract :
      p.insecure_value != "" && p.insecure_value != null
    ])
    error_message = "The SSM contract must use explicit disabled sentinels instead of empty parameter values."
  }
}

run "dns_creates_one_zone_scoped_certificate_and_identity" {
  command = apply

  variables {
    app_domain_name        = "app.example.org"
    route53_public_zone_id = "Z1234567890ABC"
  }

  assert {
    condition     = aws_acm_certificate.app[0].domain_name == "app.example.org" && aws_acm_certificate.app[0].validation_method == "DNS"
    error_message = "The app certificate must use DNS validation for the configured app hostname."
  }

  assert {
    condition     = aws_eks_pod_identity_association.external_dns[0].namespace == "kube-system" && aws_eks_pod_identity_association.external_dns[0].service_account == "external-dns"
    error_message = "Only the ExternalDNS service account in kube-system may receive the Route53 role."
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.external_dns[0].policy).Statement[2].Condition["ForAllValues:StringEquals"] == {
      "route53:ChangeResourceRecordSetsNormalizedRecordNames" = ["app.example.org", "a-_external-dns-app.example.org"]
      "route53:ChangeResourceRecordSetsRecordTypes"           = ["A", "TXT"]
      "route53:ChangeResourceRecordSetsActions"               = ["CREATE", "UPSERT", "DELETE"]
    }
    error_message = "ExternalDNS may change only the app alias and its ownership record in the one configured hosted zone."
  }

  assert {
    condition = jsondecode(aws_iam_role.external_dns[0].assume_role_policy).Statement[0].Condition.StringEquals == {
      "aws:SourceAccount"                         = "123456789012"
      "aws:RequestTag/kubernetes-namespace"       = "kube-system"
      "aws:RequestTag/kubernetes-service-account" = "external-dns"
    }
    error_message = "The Pod Identity trust must be scoped to this account and the exact ExternalDNS service account."
  }

  assert {
    condition     = aws_ssm_parameter.contract["dns/enabled"].insecure_value == "true" && aws_ssm_parameter.contract["dns/domain-name"].insecure_value == "app.example.org" && aws_ssm_parameter.contract["dns/zone-id"].insecure_value == "Z1234567890ABC"
    error_message = "The SSM contract must publish DNS inputs for dx01v2 and platform/install.sh."
  }
}

run "rejects_domain_without_public_zone" {
  command = plan

  variables {
    app_domain_name = "app.example.org"
  }

  expect_failures = [var.route53_public_zone_id]
}

run "rejects_public_zone_without_domain" {
  command = plan

  variables {
    route53_public_zone_id = "Z1234567890ABC"
  }

  expect_failures = [var.route53_public_zone_id]
}

run "rejects_wildcard_domain" {
  command = plan

  variables {
    app_domain_name        = "*.example.org"
    route53_public_zone_id = "Z1234567890ABC"
  }

  expect_failures = [var.app_domain_name]
}
