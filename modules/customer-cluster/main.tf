terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# ─── Data Sources ──────────────────────────────────────────────────────────

data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"] # Canonical (Official)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_caller_identity" "current" {}

# ─── Security Group ────────────────────────────────────────────────────────

resource "aws_security_group" "k8s_node" {
  name        = "${var.cluster_name}-customer-k8s-sg"
  description = "Security group for K3s local cluster"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "K8s API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Flannel VXLAN - required for Karpenter-provisioned nodes to join
  ingress {
    description = "Flannel VXLAN"
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    self        = true
  }

  ingress {
    description = "Kubelet API"
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                     = "${var.cluster_name}-customer-k8s-sg"
    "karpenter.sh/discovery" = var.cluster_name
  }
}

# ─── IAM Role (Base Node) ──────────────────────────────────────────────────

resource "aws_iam_role" "k8s_node" {
  name = "${var.cluster_name}-customer-k8s-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "k8s_node_secrets" {
  name = "${var.cluster_name}-customer-k8s-secrets"
  role = aws_iam_role.k8s_node.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.k8s_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "k8s_node" {
  name = "${var.cluster_name}-customer-k8s-profile"
  role = aws_iam_role.k8s_node.name
}

# ─── Karpenter IAM (Same Account) ──────────────────────────────────────────

resource "aws_iam_policy" "karpenter_controller" {
  name        = "${var.cluster_name}-karpenter-controller"
  description = "Permissions for Karpenter Controller to provision EC2 locally"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ssm:GetParameter",
          "ec2:DescribeImages",
          "ec2:RunInstances",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DeleteLaunchTemplate",
          "ec2:CreateTags",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:TagResource",
          "ec2:TerminateInstances",
          "ec2:DescribeSpotPriceHistory",
          "pricing:GetProducts"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "iam:PassRole",
          "iam:GetInstanceProfile",
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:TagInstanceProfile"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.k8s_node.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

resource "aws_iam_role" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_eks_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_eks_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node-profile"
  role = aws_iam_role.karpenter_node.name
}

# Tag the Subnet for Karpenter Discovery
resource "aws_ec2_tag" "subnet_discovery" {
  resource_id = var.subnet_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# ─── EC2 Instance (Customer K3s Cluster) ───────────────────────────────────

resource "aws_instance" "k8s_node" {
  ami           = data.aws_ami.ubuntu_arm64.id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  key_name      = var.ssh_key_name

  vpc_security_group_ids = [aws_security_group.k8s_node.id]
  iam_instance_profile   = aws_iam_instance_profile.k8s_node.name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  dynamic "instance_market_options" {
    for_each = var.enable_spot ? [1] : []
    content {
      market_type = "spot"
    }
  }

  # NOTE: Terraform heredoc only interpolates ${expr} blocks, NOT bare $VAR.
  # So $VAR is safe here and passes through verbatim to the shell script.
  user_data = <<-USERDATA
    #!/bin/bash
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
    set -ex
    echo "=== Customer Cluster Bootstrap Starting ==="

    mkdir -p /home/ubuntu/.ssh
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDFHxtEbckKo1YGpgj/AbfKBttmTeJA+PcsFcoVNDTO5 nikhil@ai-server" >> /home/ubuntu/.ssh/authorized_keys
    chown -R ubuntu:ubuntu /home/ubuntu/.ssh
    chmod 700 /home/ubuntu/.ssh
    chmod 600 /home/ubuntu/.ssh/authorized_keys

    sleep 30
    apt-get update && apt-get install -y curl jq || (sleep 30 && apt-get update && apt-get install -y curl jq)

    echo "=== Installing K3s ==="
    PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
    curl -sfL https://get.k3s.io | sh -s - server --tls-san "$PUBLIC_IP"

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    chmod 644 $KUBECONFIG
    cp $KUBECONFIG /home/ubuntu/kubeconfig.yaml
    chown ubuntu:ubuntu /home/ubuntu/kubeconfig.yaml

    echo "=== Waiting for K3s to be ready ==="
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
      if kubectl get nodes 2>/dev/null | grep -q "Ready"; then
        echo "K3s is Ready!"
        break
      fi
      echo "Waiting... attempt $i"
      sleep 10
    done

    echo "=== Installing Helm ==="
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh

    echo "=== Deploying Cert Manager ==="
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm repo update
    helm install cert-manager jetstack/cert-manager \
      --namespace cert-manager \
      --create-namespace \
      --version v1.16.0 \
      --set crds.enabled=true

    echo "=== Customer Cluster Bootstrap Complete ==="
  USERDATA

  tags = {
    Name = "${var.cluster_name}-customer-k8s-node"
  }

  lifecycle {
    ignore_changes = [user_data]
  }
}
