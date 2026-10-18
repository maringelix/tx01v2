# GitHub Actions OIDC: one provider per account (created here or read when the account already has
# it) and exact-match trust policies built with jsonencode, so terraform test can assert every
# allowed `sub`.
#
# The sub is the immutable format of GitHub, used by every repository created after 2026-07-15 and
# by the ones that opted in: repo:<owner>@<owner id>/<repository>@<repository id>:<context>. The
# name-based sub (repo:<owner>/<repository>:<context>) is not trusted: it does not match those
# repositories, and whoever registers a deleted account name again would inherit it. A repository
# that predates 2026-07-15 must opt in to immutable subject claims (docs/RUNBOOK.md, section 2);
# scripts/repo-guardrails.sh checks it.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # No thumbprint_list: optional in the AWS provider 6.x; IAM validates GitHub's certificate
  # with its own trusted root CAs.
}

# The provider of an account that already has one: read by URL, never created or changed here.
data "aws_iam_openid_connect_provider" "existing" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.existing[0].arn

  tx_subject_prefix = "repo:${var.github_owner}@${var.github_owner_id}/tx01v2@${var.tx01v2_repository_id}"
  dx_subject_prefix = "repo:${var.github_owner}@${var.github_owner_id}/dx01v2@${var.dx01v2_repository_id}"

  # The contract (docs/CONTRACT.md): exact sub claims, no wildcards. Only the apply and deploy jobs
  # use the environment lab, whose deployment branches are limited to main (repo-guardrails.sh).
  github_oidc_subjects = {
    plan = [
      "${local.tx_subject_prefix}:pull_request",
      "${local.tx_subject_prefix}:ref:refs/heads/main",
    ]
    apply  = ["${local.tx_subject_prefix}:environment:lab"]
    deploy = ["${local.dx_subject_prefix}:environment:lab"]
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
