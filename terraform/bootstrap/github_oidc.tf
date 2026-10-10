# GitHub Actions OIDC: one provider per account (created here or reused) and exact-match trust
# policies built with jsonencode, so terraform test can assert every allowed `sub`.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # No thumbprint_list: optional in the AWS provider 6.x; IAM validates GitHub's certificate
  # with its own trusted root CAs.
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_github_oidc_provider_arn

  # Contract v1 (docs/CONTRATO.md): exact sub claims, no wildcards.
  github_oidc_subjects = {
    plan = [
      "repo:${var.github_owner}/tx01v2:pull_request",
      "repo:${var.github_owner}/tx01v2:ref:refs/heads/main",
    ]
    apply  = ["repo:${var.github_owner}/tx01v2:environment:lab"]
    deploy = ["repo:${var.github_owner}/dx01v2:environment:lab"]
  }

  github_trust_policies = {
    for role, subjects in local.github_oidc_subjects : role => jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "GitHubActionsOidc"
        Effect    = "Allow"
        Principal = { Federated = local.github_oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = subjects
          }
        }
      }]
    })
  }
}
