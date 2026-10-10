# EKS Pod Identity (no IRSA OIDC provider) for the two platform controllers installed by
# platform/install.sh. Both trust policies are limited to this account and this cluster.

locals {
  # Must match LBC_CHART_VERSION in platform/versions.env (checked by the harness).
  load_balancer_controller_version = "3.6.0"

  pod_identity_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EksPodIdentityOfThisCluster"
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnEquals    = { "aws:SourceArn" = local.cluster_arn }
      }
    }]
  })
}

# --- AWS Load Balancer Controller: kube-system/aws-load-balancer-controller ---

resource "aws_iam_role" "load_balancer_controller" {
  name               = "${var.name}-aws-load-balancer-controller"
  description        = "AWS Load Balancer Controller of ${var.name} (EKS Pod Identity)."
  assume_role_policy = local.pod_identity_trust_policy
}

resource "aws_iam_policy" "load_balancer_controller" {
  name        = "${var.name}-aws-load-balancer-controller"
  description = "Upstream IAM policy of AWS Load Balancer Controller v${local.load_balancer_controller_version}, kept verbatim."
  policy      = file("${path.module}/policies/aws-load-balancer-controller-v${local.load_balancer_controller_version}.json")
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}

resource "aws_eks_pod_identity_association" "load_balancer_controller" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.load_balancer_controller.arn
}

# --- External Secrets Operator: external-secrets/external-secrets ---

resource "aws_iam_role" "external_secrets" {
  name               = "${var.name}-external-secrets"
  description        = "External Secrets Operator of ${var.name} (EKS Pod Identity)."
  assume_role_policy = local.pod_identity_trust_policy
}

resource "aws_iam_role_policy" "external_secrets" {
  name = "read-lab-secrets"
  role = aws_iam_role.external_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadLabSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = "arn:${local.partition}:secretsmanager:${local.region}:${local.account_id}:secret:${var.name}/*"
      },
      {
        Sid      = "DecryptThroughSecretsManagerOnly"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = var.kms_key_arn
        Condition = {
          StringEquals = { "kms:ViaService" = "secretsmanager.${local.region}.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
}
