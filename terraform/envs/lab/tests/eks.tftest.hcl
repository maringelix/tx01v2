# modules/eks tested directly (run blocks with a module source) so assertions can read the
# resources inside the module.

mock_provider "aws" {
  source = "../../tests/mocks"
}

variables {
  github_owner                 = "maringelix"
  name                         = "tx01v2-lab"
  cluster_version              = "1.36"
  private_subnet_ids           = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0aaaaaaaaaaaaaaa2"]
  endpoint_public_access_cidrs = ["203.0.113.10/32"]
  kms_key_arn                  = "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
  log_retention_days           = 7
  node_capacity_type           = "SPOT"
  node_instance_types          = ["t3.medium", "t3a.medium"]
  node_desired_size            = 2
  node_min_size                = 1
  node_max_size                = 3
  node_disk_size_gb            = 20
  cluster_admin_principal_arns = ["arn:aws:iam::123456789012:role/tx01v2-gha-apply", "arn:aws:iam::123456789012:role/Admin"]
  app_deployer_principal_arns  = ["arn:aws:iam::123456789012:role/dx01v2-gha-deploy"]
  tags                         = { Project = "tx01v2", Environment = "lab" }
  permissions_boundary_arn     = "arn:aws:iam::123456789012:policy/tx01v2-lab-boundary"
}

run "capacity_controller_and_spot" {
  command = plan
  module { source = "../../modules/eks" }
  variables { enable_spot_pool = true }
  assert {
    condition = (
      aws_eks_node_group.default.capacity_type == "ON_DEMAND" &&
      aws_eks_node_group.spot[0].capacity_type == "SPOT" &&
      aws_eks_node_group.spot[0].scaling_config[0].min_size == 0 &&
      aws_eks_node_group.spot[0].scaling_config[0].max_size == 2 &&
      one(aws_eks_node_group.spot[0].taint).effect == "NO_SCHEDULE" &&
      aws_eks_pod_identity_association.cluster_autoscaler.namespace == "kube-system" &&
      aws_eks_pod_identity_association.cluster_autoscaler.service_account == "cluster-autoscaler" &&
      aws_iam_role.cluster_autoscaler.permissions_boundary == var.permissions_boundary_arn
    )
    error_message = "Capacity profile needs an actual Pod Identity controller and tainted bounded Spot alongside on-demand."
  }
  assert {
    condition = (
      jsondecode(aws_iam_role_policy.cluster_autoscaler.policy).Statement[2].Condition.StringEquals["aws:ResourceTag/k8s.io/cluster-autoscaler/tx01v2-lab"] == "owned" &&
      jsondecode(aws_iam_role_policy.cluster_autoscaler.policy).Statement[2].Condition.StringEquals["aws:ResourceTag/k8s.io/cluster-autoscaler/enabled"] == "true" &&
      length(aws_autoscaling_group_tag.default_discovery) == 2 &&
      length(aws_autoscaling_group_tag.spot_discovery) == 4
    )
    error_message = "Scaling writes and auto-discovery must be limited to tagged owned groups."
  }
}

run "control_plane" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  assert {
    condition = alltrue([
      for r in [
        aws_iam_role.cluster,
        aws_iam_role.node,
        aws_iam_role.load_balancer_controller,
        aws_iam_role.external_secrets,
        aws_iam_role.otel_collector,
        aws_iam_role.trivy_operator,
        aws_iam_role.kyverno_image_verifier,
        aws_iam_role.ebs_csi,
      ] : r.permissions_boundary == "arn:aws:iam::123456789012:policy/tx01v2-lab-boundary"
    ])
    error_message = "Every IAM role of the cluster must carry the permissions boundary of the lab (SEC-11): the apply role cannot create one without it."
  }

  assert {
    condition     = aws_eks_cluster.this.name == "tx01v2-lab" && aws_eks_cluster.this.version == "1.36"
    error_message = "Cluster tx01v2-lab must run Kubernetes 1.36."
  }

  assert {
    condition     = aws_eks_cluster.this.upgrade_policy[0].support_type == "STANDARD"
    error_message = "upgrade_policy.support_type must be STANDARD (no extended support surcharge)."
  }

  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API" && aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions == false
    error_message = "Authentication must be API-only and the creator must not get implicit admin."
  }

  assert {
    condition     = aws_eks_cluster.this.bootstrap_self_managed_addons == false && aws_eks_cluster.this.deletion_protection == false
    error_message = "Self-managed add-ons must not be bootstrapped; the lab cluster must stay destroyable."
  }

  assert {
    condition = (
      aws_eks_cluster.this.vpc_config[0].endpoint_private_access &&
      aws_eks_cluster.this.vpc_config[0].endpoint_public_access &&
      aws_eks_cluster.this.vpc_config[0].public_access_cidrs == toset(["203.0.113.10/32"])
    )
    error_message = "The public endpoint must be restricted to endpoint_public_access_cidrs, with private access on."
  }

  assert {
    condition = (
      aws_eks_cluster.this.encryption_config[0].resources == toset(["secrets"]) &&
      aws_eks_cluster.this.encryption_config[0].provider[0].key_arn == var.kms_key_arn
    )
    error_message = "Kubernetes secrets must be envelope-encrypted with the lab key."
  }

  assert {
    condition     = aws_eks_cluster.this.enabled_cluster_log_types == toset(["api", "audit", "authenticator", "controllerManager", "scheduler"])
    error_message = "All five control plane log types must be enabled."
  }

  assert {
    condition = (
      aws_cloudwatch_log_group.cluster.name == "/aws/eks/tx01v2-lab/cluster" &&
      aws_cloudwatch_log_group.cluster.retention_in_days == 7 &&
      aws_cloudwatch_log_group.cluster.kms_key_id == var.kms_key_arn
    )
    error_message = "The control plane log group must be pre-created with retention and KMS."
  }
}

run "nodes" {
  command = apply

  module {
    source = "../../modules/eks"
  }

  assert {
    condition = (
      aws_launch_template.node.metadata_options[0].http_tokens == "required" &&
      aws_launch_template.node.metadata_options[0].http_put_response_hop_limit == 1 &&
      aws_launch_template.node.metadata_options[0].http_endpoint == "enabled"
    )
    error_message = "Nodes must require IMDSv2 tokens with a hop limit of 1."
  }

  assert {
    condition = (
      aws_launch_template.node.vpc_security_group_ids == null &&
      aws_launch_template.node.security_group_names == null &&
      length(aws_launch_template.node.network_interfaces) == 0
    )
    error_message = "The launch template must not set security groups (EKS must attach the cluster security group)."
  }

  assert {
    condition     = aws_launch_template.node.image_id == null && aws_launch_template.node.user_data == null && aws_launch_template.node.instance_type == null
    error_message = "The launch template must leave AMI, user data and instance type to EKS / the node group."
  }

  assert {
    condition = (
      aws_launch_template.node.block_device_mappings[0].device_name == "/dev/xvda" &&
      aws_launch_template.node.block_device_mappings[0].ebs[0].volume_type == "gp3" &&
      aws_launch_template.node.block_device_mappings[0].ebs[0].encrypted == "true" &&
      aws_launch_template.node.block_device_mappings[0].ebs[0].volume_size == 20
    )
    error_message = "The root volume must be an encrypted 20 GB gp3 volume defined in the launch template."
  }

  assert {
    condition     = aws_eks_node_group.default.disk_size == -1
    error_message = "The node group must not set disk_size (the mock sentinel -1 was overwritten by configuration)."
  }

  assert {
    condition = (
      aws_eks_node_group.default.capacity_type == "SPOT" &&
      aws_eks_node_group.default.ami_type == "AL2023_x86_64_STANDARD" &&
      aws_eks_node_group.default.instance_types == tolist(["t3.medium", "t3a.medium"])
    )
    error_message = "The node group must be AL2023 x86_64 on SPOT with the configured instance types."
  }

  assert {
    condition = (
      aws_eks_node_group.default.scaling_config[0].desired_size == 2 &&
      aws_eks_node_group.default.scaling_config[0].min_size == 1 &&
      aws_eks_node_group.default.scaling_config[0].max_size == 3
    )
    error_message = "Node group sizes must follow the variables."
  }

  assert {
    condition     = aws_eks_node_group.default.launch_template[0].id == aws_launch_template.node.id
    error_message = "The node group must use the module launch template."
  }

  assert {
    condition = toset([for a in aws_iam_role_policy_attachment.node : a.policy_arn]) == toset([
      "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
      "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
      "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    ])
    error_message = "The node role must have exactly the three node policies."
  }
}

run "addons" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  assert {
    condition     = toset(keys(aws_eks_addon.before_compute)) == toset(["vpc-cni", "kube-proxy", "eks-pod-identity-agent"])
    error_message = "vpc-cni, kube-proxy and eks-pod-identity-agent must be installed before the nodes."
  }

  assert {
    condition     = toset(keys(aws_eks_addon.after_compute)) == toset(["aws-ebs-csi-driver", "coredns", "metrics-server"])
    error_message = "aws-ebs-csi-driver, coredns and metrics-server must be installed after the nodes."
  }

  assert {
    condition     = jsondecode(aws_eks_addon.before_compute["vpc-cni"].configuration_values) == { enableNetworkPolicy = "true" }
    error_message = "vpc-cni must enable network policy enforcement."
  }

  assert {
    condition     = alltrue([for k, v in data.aws_eks_addon_version.this : v.kubernetes_version == "1.36" && v.most_recent == false])
    error_message = "Add-ons must use the default version for the cluster Kubernetes version."
  }
}

run "pod_identity" {
  command = apply

  module {
    source = "../../modules/eks"
  }

  assert {
    condition = (
      aws_eks_pod_identity_association.load_balancer_controller.namespace == "kube-system" &&
      aws_eks_pod_identity_association.load_balancer_controller.service_account == "aws-load-balancer-controller" &&
      aws_eks_pod_identity_association.external_secrets.namespace == "external-secrets" &&
      aws_eks_pod_identity_association.external_secrets.service_account == "external-secrets" &&
      aws_eks_pod_identity_association.otel_collector.namespace == "observability" &&
      aws_eks_pod_identity_association.otel_collector.service_account == "opentelemetry-collector" &&
      aws_eks_pod_identity_association.trivy_operator.namespace == "trivy-system" &&
      aws_eks_pod_identity_association.trivy_operator.service_account == "trivy-operator" &&
      aws_eks_pod_identity_association.kyverno_image_verifier.namespace == "kyverno" &&
      aws_eks_pod_identity_association.kyverno_image_verifier.service_account == "kyverno-admission-controller" &&
      aws_eks_pod_identity_association.ebs_csi.namespace == "kube-system" &&
      aws_eks_pod_identity_association.ebs_csi.service_account == "ebs-csi-controller-sa"
    )
    error_message = "Pod Identity associations must target the contract service accounts."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.otel_collector_xray.policy_arn == "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
    error_message = "The OpenTelemetry Collector may only write to X-Ray (AWSXRayDaemonWriteAccess)."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.ebs_csi.policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicyV2"
    error_message = "The EBS CSI driver must use the tag-scoped AWS managed policy V2."
  }

  assert {
    condition = alltrue([
      for r in [aws_iam_role.load_balancer_controller, aws_iam_role.external_secrets, aws_iam_role.otel_collector, aws_iam_role.trivy_operator, aws_iam_role.kyverno_image_verifier, aws_iam_role.ebs_csi] :
      jsondecode(r.assume_role_policy).Statement == [{
        Sid       = "EksPodIdentityOfThisCluster"
        Effect    = "Allow"
        Principal = { Service = "pods.eks.amazonaws.com" }
        Action    = ["sts:AssumeRole", "sts:TagSession"]
        Condition = {
          StringEquals = { "aws:SourceAccount" = "123456789012" }
          ArnEquals    = { "aws:SourceArn" = "arn:aws:eks:us-east-1:123456789012:cluster/tx01v2-lab" }
        }
      }]
    ])
    error_message = "Pod Identity roles must trust pods.eks.amazonaws.com for this account and cluster only."
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.external_secrets.policy).Statement == [
      {
        Sid      = "ReadLabSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = "arn:aws:secretsmanager:us-east-1:123456789012:secret:tx01v2-lab/*"
      },
      {
        Sid       = "DecryptThroughSecretsManagerOnly"
        Effect    = "Allow"
        Action    = "kms:Decrypt"
        Resource  = "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
        Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.us-east-1.amazonaws.com" } }
      },
    ]
    error_message = "The ESO policy must match the contract."
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.trivy_operator_ecr.policy).Statement == [
      {
        Sid      = "AuthenticateToEcr"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "ReadOnlyTheAppRepositories"
        Effect = "Allow"
        Action = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = [
          "arn:aws:ecr:us-east-1:123456789012:repository/dx01v2/api",
          "arn:aws:ecr:us-east-1:123456789012:repository/dx01v2/web",
        ]
      },
    ]
    error_message = "Trivy may authenticate to ECR and read only the two app repositories."
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.kyverno_image_verifier_ecr.policy).Statement == [
      {
        Sid      = "AuthenticateToEcr"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "ReadOnlyTheAppRepositories"
        Effect = "Allow"
        Action = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = [
          "arn:aws:ecr:us-east-1:123456789012:repository/dx01v2/api",
          "arn:aws:ecr:us-east-1:123456789012:repository/dx01v2/web",
        ]
      },
    ]
    error_message = "Kyverno may authenticate to ECR and read only the two app repositories."
  }

  assert {
    condition     = jsondecode(aws_iam_policy.load_balancer_controller.policy) == jsondecode(file("../../modules/eks/policies/aws-load-balancer-controller-v3.6.0.json"))
    error_message = "The LBC policy must be the committed upstream v3.6.0 file."
  }
}

run "access_entries" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  assert {
    condition     = toset(keys(aws_eks_access_entry.cluster_admin)) == toset(var.cluster_admin_principal_arns) && alltrue([for e in aws_eks_access_entry.cluster_admin : e.type == "STANDARD"])
    error_message = "Every cluster admin principal must get a STANDARD access entry."
  }

  assert {
    condition = alltrue([
      for a in aws_eks_access_policy_association.cluster_admin :
      a.policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy" && a.access_scope[0].type == "cluster"
    ]) && length(aws_eks_access_policy_association.cluster_admin) == 2
    error_message = "Cluster admins must get AmazonEKSClusterAdminPolicy with cluster scope."
  }

  assert {
    condition = (
      aws_eks_access_entry.app_deployer["arn:aws:iam::123456789012:role/dx01v2-gha-deploy"].type == "STANDARD" &&
      aws_eks_access_entry.app_deployer["arn:aws:iam::123456789012:role/dx01v2-gha-deploy"].kubernetes_groups == toset(["dx01v2-deployers"])
    )
    error_message = "The app deployer must be a STANDARD entry in the dx01v2-deployers group."
  }
}

run "on_demand_is_opt_in" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    node_capacity_type = "ON_DEMAND"
  }

  assert {
    condition     = aws_eks_node_group.default.capacity_type == "ON_DEMAND"
    error_message = "node_capacity_type must reach the node group."
  }
}
