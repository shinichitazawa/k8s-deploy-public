# Ubuntu 24.04 arm64 AMI を Canonical 公開 SSM パラメータから取得
data "aws_ssm_parameter" "ubuntu" {
  name = var.ubuntu_ssm_parameter
}

# default VPC / 全サブネット（複数 AZ に Spot を分散させるため全部使う）
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  # subnet_id 指定時はそれのみ、未指定なら default VPC の全サブネット(全AZ)
  subnet_ids = var.subnet_id != "" ? [var.subnet_id] : data.aws_subnets.default.ids
}

resource "aws_security_group" "node" {
  name        = "k3s-cilium-ec2-node"
  description = "k3s cilium hybrid node via tailscale"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH (fallback; prefer Tailscale SSH)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_ingress_cidrs
  }

  egress {
    description = "all outbound (Tailscale / k3s join / apt)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "k3s-cilium-ec2-node" }
}

# --- ノード用 IAM ロール(instance profile) ---
# このノード上の pod は IMDS 経由でこのロールを assume して AWS を叩ける（静的キー不要）。
# taint で専有し、AWS 操作が要る pod だけを載せる前提。
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name_prefix        = "${var.node_name}-node-"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = { Name = "${var.node_name}-node" }
}

# 権限は burrito-runner 相当（将来この node で Burrito runner を回し静的キーを廃止する布石）。
resource "aws_iam_role_policy" "node" {
  name_prefix = "aws-ops-"
  role        = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "Ec2", Effect = "Allow", Action = "ec2:*", Resource = "*",
      Condition = { StringEquals = { "aws:RequestedRegion" = var.region } } },
      { Sid = "AutoScaling", Effect = "Allow", Action = "autoscaling:*", Resource = "*",
      Condition = { StringEquals = { "aws:RequestedRegion" = var.region } } },
      { Sid = "Slr", Effect = "Allow", Action = "iam:CreateServiceLinkedRole", Resource = "*",
      Condition = { StringEquals = { "iam:AWSServiceName" = ["autoscaling.amazonaws.com", "spot.amazonaws.com"] } } },
      { Sid = "Ssm", Effect = "Allow", Action = ["ssm:GetParameter", "ssm:GetParameters"],
      Resource = "arn:aws:ssm:${var.region}::parameter/aws/service/canonical/ubuntu/*" },
      { Sid = "State", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
      Resource = ["arn:aws:s3:::example-terraform-state", "arn:aws:s3:::example-terraform-state/ec2/k3s-cilium-hybrid-node/*"] },
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  name_prefix = "${var.node_name}-"
  role        = aws_iam_role.node.name
}

# Launch Template（AMI / user_data / SG / IMDSv2 / instance profile）
resource "aws_launch_template" "node" {
  name_prefix = "${var.node_name}-"
  image_id    = data.aws_ssm_parameter.ubuntu.value
  user_data   = base64encode(local.user_data)

  # public_ip=true: 共有 egress 用に public IP を付与(default VPC の public サブネット前提)。
  # public_ip=false: 完全 private(public IP 無し)。この場合 subnet_id に NAT 経路のある
  # private サブネットを指定すること(AWS の NAT GW は共有前提のため本モジュールでは作らない)。
  network_interfaces {
    associate_public_ip_address = var.public_ip
    security_groups             = [aws_security_group.node.id]
    delete_on_termination       = true
  }

  iam_instance_profile {
    arn = aws_iam_instance_profile.node.arn
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
    # pod(=host から 1 hop)が IMDS に届くよう hop limit を 2 に。taint 専有前提。
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.node_name}-k3s-spot" }
  }

  lifecycle {
    ignore_changes = [image_id] # AMI 更新で毎回作り直さない
  }
}

# Auto Scaling Group + Mixed Instances Policy(Spot, price-capacity-optimized)
resource "aws_autoscaling_group" "node" {
  name_prefix         = "${var.node_name}-"
  desired_capacity    = var.desired_capacity
  min_size            = var.min_size
  max_size            = var.max_size
  vpc_zone_identifier = local.subnet_ids

  # Spot 中断予兆で先回り置換（自己修復）
  capacity_rebalance = true

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = var.on_demand_base
      on_demand_percentage_above_base_capacity = var.on_demand_percentage
      spot_allocation_strategy                 = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.node.id
        version            = "$Latest"
      }

      # 複数 arm64 タイプ = Spot プールを増やして在庫を取りやすくする
      dynamic "override" {
        for_each = var.instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.node_name}-k3s-spot"
    propagate_at_launch = true
  }

  # 起動した instance が k3s に join するまで少し猶予
  health_check_type         = "EC2"
  health_check_grace_period = 180

  lifecycle {
    # Cluster Autoscaler が desired_capacity を管理するため TF は戻さない(競合回避)。
    ignore_changes = [desired_capacity]
  }
}
