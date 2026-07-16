# ─── IAM: Cluster Role ───────────────────────────────────────────────────────

resource "aws_iam_role" "cluster" {
  name = "${var.default["env"]}-${var.default["project"]}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "cluster_vpc_resource_controller" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

# ─── IAM: Node Group Role ─────────────────────────────────────────────────────

resource "aws_iam_role" "node_group" {
  name = "${var.default["env"]}-${var.default["project"]}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_readonly" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}


resource "aws_iam_policy" "node_secrets_manager" {
  name = "${var.default["env"]}-${var.default["project"]}-node-secrets-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [
          "arn:aws:secretsmanager:${var.default["region"]}:*:secret:${var.default["project"]}/*",
          "arn:aws:secretsmanager:${var.default["region"]}:*:secret:claude/*",
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "node_secrets_manager" {
  role       = aws_iam_role.node_group.name
  policy_arn = aws_iam_policy.node_secrets_manager.arn
}

# ─── Security Group: Cluster ──────────────────────────────────────────────────

resource "aws_security_group" "cluster" {
  name        = "${var.default["env"]}-${var.default["project"]}-eks-cluster-sg"
  description = "EKS cluster control plane security group"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.default["env"]}-${var.default["project"]}-eks-cluster-sg"
  }
}

# Karpenter nodes (nodes SG) and managed nodes (cluster SG) are in different SGs.
# Without these rules, pod-to-pod traffic across the two node groups is dropped —
# including DNS queries from Karpenter node pods to CoreDNS on managed nodes,
# and API server access from Karpenter node pods.
resource "aws_security_group_rule" "cluster_ingress_from_nodes_all" {
  description              = "Allow all pod traffic from Karpenter nodes to managed nodes (CoreDNS etc.)"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.cluster.id
  source_security_group_id = aws_security_group.nodes.id
}

resource "aws_security_group_rule" "nodes_ingress_from_cluster_all" {
  description              = "Allow all pod traffic from managed nodes to Karpenter nodes"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.nodes.id
  source_security_group_id = aws_security_group.cluster.id
}

# ─── Security Group: Nodes ────────────────────────────────────────────────────

resource "aws_security_group" "nodes" {
  name        = "${var.default["env"]}-${var.default["project"]}-eks-nodes-sg"
  description = "EKS managed node group security group"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow nodes to communicate with each other"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  ingress {
    description     = "Allow control plane to reach nodes"
    from_port       = 1025
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.cluster.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # MCP Tunnel: cloudflared maintains an outbound tunnel to Cloudflare edge.
  # Explicit rule documents intent; the broad egress above already covers this.
  egress {
    description = "MCP Tunnel: Cloudflare edge (outbound only, no inbound needed)"
    from_port   = 7844
    to_port     = 7844
    protocol    = "tcp"
    cidr_blocks = ["198.41.192.0/19"]
  }

  egress {
    description = "MCP Tunnel: Cloudflare edge UDP"
    from_port   = 7844
    to_port     = 7844
    protocol    = "udp"
    cidr_blocks = ["198.41.192.0/19"]
  }

  tags = {
    Name                     = "${var.default["env"]}-${var.default["project"]}-eks-nodes-sg"
    "karpenter.sh/discovery" = "${var.default["env"]}-${var.default["project"]}-eks"
  }

  # EKS automatically adds/modifies ingress rules on this SG for node-to-API
  # server connectivity. Ignore those changes to prevent spurious diffs on every apply.
  lifecycle {
    ignore_changes = [ingress, egress]
  }
}

# ─── EKS Cluster ─────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "cluster" {
  name     = "${var.default["env"]}-${var.default["project"]}-eks"
  role_arn = aws_iam_role.cluster.arn
  version  = lookup(var.eks, "kubernetes_version", "1.31")

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = lookup(var.eks, "endpoint_public_access", false)
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_iam_role_policy_attachment.cluster_vpc_resource_controller,
  ]

  tags = {
    Name                     = "${var.default["env"]}-${var.default["project"]}-eks"
    "karpenter.sh/discovery" = "${var.default["env"]}-${var.default["project"]}-eks"
  }
}

# ─── KMS Key for Secrets Encryption ──────────────────────────────────────────

resource "aws_kms_key" "eks" {
  description             = "EKS secrets encryption key for ${var.default["env"]}-${var.default["project"]}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "${var.default["env"]}-${var.default["project"]}-eks-kms"
  }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.default["env"]}-${var.default["project"]}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# ─── EKS Managed Node Group ───────────────────────────────────────────────────

resource "aws_eks_node_group" "general" {
  cluster_name    = aws_eks_cluster.cluster.name
  node_group_name = "general-nodegroup"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = var.private_subnet_ids

  # EKS-managed Amazon Linux 2023 AMI — automatically kept up to date
  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = lookup(var.eks, "node_instance_types", ["m5.xlarge"])
  capacity_type  = lookup(var.eks, "capacity_type", "ON_DEMAND")

  scaling_config {
    desired_size = lookup(var.eks, "desired_size", 2)
    min_size     = lookup(var.eks, "min_size", 2)
    max_size     = lookup(var.eks, "max_size", 4)
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_readonly,
  ]

  tags = {
    Name = "general-nodegroup"
  }
}

# ─── Launch Template (IMDSv2 + encrypted root volume) ─────────────────────────
# Note: no image_id or vpc_security_group_ids — EKS manages the AMI and node SGs
# when ami_type is set on the node group. Only override disk and metadata options.

resource "aws_launch_template" "nodes" {
  name_prefix = "${var.default["env"]}-${var.default["project"]}-eks-lt-"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = lookup(var.eks, "node_disk_size", 50)
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 enforced
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.default["env"]}-${var.default["project"]}-eks-node"
    }
  }
}

# Tag the EKS-managed cluster SG so Karpenter nodes receive it via securityGroupSelectorTerms.
# Managed nodes already carry this SG (EKS attaches it automatically); Karpenter nodes
# picking it up gives them the same self-referencing all-traffic rule, restoring pod DNS
# and cross-node pod communication (e.g. CoreDNS on managed nodes → Karpenter node pods).
resource "aws_ec2_tag" "cluster_sg_karpenter_discovery" {
  resource_id = aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = "${var.default["env"]}-${var.default["project"]}-eks"
}

# ─── EKS Access Entry: allow node role to join cluster ───────────────────────

resource "aws_eks_access_entry" "node_group" {
  cluster_name  = aws_eks_cluster.cluster.name
  principal_arn = aws_iam_role.node_group.arn
  type          = "EC2_LINUX"

  depends_on = [aws_eks_cluster.cluster]
}

# ─── OIDC Provider (for IRSA) ─────────────────────────────────────────────────

data "tls_certificate" "eks" {
  url = aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.cluster.identity[0].oidc[0].issuer

  tags = {
    Name = "${var.default["env"]}-${var.default["project"]}-eks-oidc"
  }
}
