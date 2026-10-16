# EKS Pod Identity (no IRSA OIDC provider) for the platform components installed by
# platform/install.sh. Every trust policy is limited to this account and this cluster.

locals {
  # Must match LBC_CHART_VERSION in platform/versions.env (checked by the harness).
  load_balancer_controller_version = "3.6.0"
  trivy_ecr_repository_arns = [
    for repo in ["dx01v2/api", "dx01v2/web"] : "arn:${local.partition}:ecr:${local.region}:${local.account_id}:repository/${repo}"
  ]

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
  name                 = "${var.name}-aws-load-balancer-controller"
  description          = "AWS Load Balancer Controller of ${var.name} (EKS Pod Identity)."
  assume_role_policy   = local.pod_identity_trust_policy
  permissions_boundary = var.permissions_boundary_arn
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
  name                 = "${var.name}-external-secrets"
  description          = "External Secrets Operator of ${var.name} (EKS Pod Identity)."
  assume_role_policy   = local.pod_identity_trust_policy
  permissions_boundary = var.permissions_boundary_arn
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

# --- OpenTelemetry Collector: observability/opentelemetry-collector (traces to AWS X-Ray) ---

resource "aws_iam_role" "otel_collector" {
  name                 = "${var.name}-otel-collector"
  description          = "OpenTelemetry Collector of ${var.name}: writes traces to AWS X-Ray (EKS Pod Identity)."
  assume_role_policy   = local.pod_identity_trust_policy
  permissions_boundary = var.permissions_boundary_arn
}

# X-Ray has no resource-level permissions: PutTraceSegments, PutTelemetryRecords and the sampling
# reads of the AWS managed policy for the X-Ray daemon, nothing else.
resource "aws_iam_role_policy_attachment" "otel_collector_xray" {
  role       = aws_iam_role.otel_collector.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_eks_pod_identity_association" "otel_collector" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "observability"
  service_account = "opentelemetry-collector"
  role_arn        = aws_iam_role.otel_collector.arn
}

# --- Trivy Operator: trivy-system/trivy-operator (read only the two private app images) ---

resource "aws_iam_role" "trivy_operator" {
  name                 = "${var.name}-trivy-operator"
  description          = "Trivy Operator of ${var.name}: scan the two private dx01v2 ECR repositories."
  assume_role_policy   = local.pod_identity_trust_policy
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy" "trivy_operator_ecr" {
  name = "scan-private-app-images"
  role = aws_iam_role.trivy_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AuthenticateToEcr"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "ReadOnlyTheAppRepositories"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = local.trivy_ecr_repository_arns
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "trivy_operator" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "trivy-system"
  service_account = "trivy-operator"
  role_arn        = aws_iam_role.trivy_operator.arn
}

# --- EBS CSI: kube-system/ebs-csi-controller-sa (encrypted gp3 PVCs for observability) ---

resource "aws_iam_role" "ebs_csi" {
  name                 = "${var.name}-ebs-csi"
  description          = "EBS CSI driver of ${var.name}: provision only tagged EBS volumes and snapshots."
  assume_role_policy   = local.pod_identity_trust_policy
  permissions_boundary = var.permissions_boundary_arn
}

# AWS's V2 policy scopes volume and snapshot actions to resources tagged by the EBS CSI driver.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicyV2"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}
