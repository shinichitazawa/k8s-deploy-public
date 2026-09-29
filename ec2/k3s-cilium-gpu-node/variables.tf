variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "profile" {
  description = "AWS CLI profile (Terrakube では実行環境の認証に置き換え可)"
  type        = string
  default     = "example-env"
}

variable "instance_types" {
  description = "ASG Mixed Instances の候補 GPU タイプ群。g6 系 = NVIDIA L4 24GB。g6.2xlarge(8vCPU/32GB) が H3 要件(RAM24GB+/VRAM16GB+)の最小、g6.4xlarge は在庫フォールバック"
  type        = list(string)
  default     = ["g6.2xlarge", "g6.4xlarge"]
}

variable "disk_size_gb" {
  description = "ルート EBS(gp3, GB)。モデル重みとコンテナイメージで嵩むため既定 80"
  type        = number
  default     = 80
}

variable "desired_capacity" {
  description = "ASG 希望ノード数。ゼロスケール運用は 0(CA が pending Pod で起こす)。テスト時は 1"
  type        = number
  default     = 0
}

variable "min_size" {
  description = "ASG 最小ノード数(ゼロスケール = 0)"
  type        = number
  default     = 0
}

variable "max_size" {
  description = "ASG 最大ノード数（Spot 置換時の一時的重複を許容するなら 2）"
  type        = number
  default     = 2
}

variable "on_demand_base" {
  description = "on-demand で必ず確保する台数（0=全 Spot）"
  type        = number
  default     = 0
}

variable "on_demand_percentage" {
  description = "base を超えた分の on-demand 比率（0=全 Spot、100=全 on-demand）"
  type        = number
  default     = 0
}

variable "node_name" {
  description = "k3s node 名 prefix かつ Tailscale hostname prefix（instance-id を付加して一意化）"
  type        = string
  default     = "ec2-gpu"
}

variable "node_taint" {
  description = "ノードに付ける taint（GPU 専有）。GPU ワークロード側は toleration dedicated=gpu-ops を付ける"
  type        = string
  default     = "dedicated=gpu-ops:NoSchedule"
}

variable "ubuntu_ssm_parameter" {
  description = "Ubuntu 24.04 amd64 AMI を引く Canonical 公開 SSM パラメータ(g6 は x86_64)"
  type        = string
  default     = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

variable "ssh_ingress_cidrs" {
  description = "SSH(22) を許可する CIDR。運用は Tailscale SSH 経由を推奨、これは fallback"
  type        = list(string)
  default     = ["203.0.113.101/32"]
}

variable "subnet_id" {
  description = "特定 subnet に固定したい場合に指定。空なら default VPC の全サブネット(全AZ)に Spot を分散"
  type        = string
  default     = ""
}

# --- k3s join ---
variable "k3s_cp_host" {
  description = "k3s control-plane(rpi0) の到達先。純オーバーレイ設計。rpi0 の MagicDNS FQDN(<host>.<tailnet>.ts.net) 推奨、Tailscale IP(100.x)も可。いずれも rpi0 側で --tls-san に追加済みであること"
  type        = string
  # rpi0 の MagicDNS 名(推奨) か TS IP を tfvars/Terrakube 変数で渡す
  default = ""

  validation {
    condition     = can(regex("\\.ts\\.net$", var.k3s_cp_host)) || can(regex("^100\\.", var.k3s_cp_host))
    error_message = "k3s_cp_host は rpi0 の MagicDNS FQDN(<host>.<tailnet>.ts.net) か Tailscale IP(100.x.y.z)を指定してください。"
  }
}

variable "k3s_cp_port" {
  description = "k3s API port"
  type        = number
  default     = 6443
}

variable "k3s_version" {
  description = "k3s agent バージョン (server=rpi0 と一致させる。kubelet は server より新しくできない)"
  type        = string
  default     = "v1.36.2+k3s1"
}

variable "k3s_token" {
  description = "k3s node-token (/var/lib/rancher/k3s/server/node-token)。秘匿。リポジトリにコミットしない"
  type        = string
  sensitive   = true
}

# --- Tailscale ---
variable "tailscale_authkey" {
  description = "Tailscale auth key (tskey-auth-...)。秘匿。リポジトリにコミットしない"
  type        = string
  sensitive   = true
}

variable "public_ip" {
  description = "true=各インスタンスに public IP(共有 egress、default VPC 前提)。false=完全 private(public IP 無し)。false の場合は subnet_id に NAT 経路のある private サブネットを指定すること。既定は現状維持の true"
  type        = bool
  default     = true
}

variable "nat_type" {
  description = <<-EOT
    public_ip=false(完全private)時の egress 方式の指針。
    - "instance"(既定): 小型 NAT インスタンス方式。AWS は default VPC が全 public のため
      本モジュールでは NAT を自動作成せず、fck-nat(https://github.com/AndrewGuenther/fck-nat)
      等で NAT インスタンスを立て、private サブネット(subnet_id)の route を向ける運用を推奨。
    - "gateway": マネージド NAT Gateway(高コスト・固定 ~$45/月)。
    GCP/Azure モジュールは instance を自己完結で構築するが、AWS はサブネット構成に依存するため注記に留める。
    public_ip=true では未使用。
  EOT
  type        = string
  default     = "instance"
  validation {
    condition     = contains(["instance", "gateway"], var.nat_type)
    error_message = "nat_type must be \"instance\" or \"gateway\"."
  }
}
