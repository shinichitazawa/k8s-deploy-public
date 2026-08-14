variable "project" {
  description = "GCP プロジェクト ID"
  type        = string
  default     = "st-datalakehouse"
}

variable "region" {
  description = "GCP リージョン(subnet 用)"
  type        = string
  default     = "asia-northeast1"
}

# ★ zonal MIG のゾーン。cluster-autoscaler(GCE provider)が zonal MIG の URL
#   (.../zones/<zone>/instanceGroups/<name>)しか受け付けないため zonal 化した。
#   CA の gce.conf の local-zone とこの値を必ず一致させること。
#   トレードオフ: Spot 在庫が単一ゾーンに限られる(regional のクロスゾーン耐性は失う)。
variable "zone" {
  description = "zonal MIG を置くゾーン(var.region 内)。CA gce.conf の local-zone と一致必須。"
  type        = string
  default     = "asia-northeast1-a"
}

variable "subnet_cidr" {
  description = "専用 subnet の CIDR"
  type        = string
  default     = "10.201.0.0/24"
}

variable "machine_type" {
  description = "コスト最優先。最安の共有コア e2-micro。"
  type        = string
  default     = "e2-micro"
}

variable "image" {
  description = "OS イメージ(family)。x86_64 Ubuntu 24.04 LTS。"
  type        = string
  default     = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"
}

# --- MIG サイズ（cluster-autoscaler で 0↔N。zero-scale は min=0 を CA 側に設定）---
variable "target_size" {
  description = "MIG 初期台数。ゼロスケール運用では 0（CA が pending pod で増やす）。テスト時は 1。"
  type        = number
  default     = 1
}

variable "node_name" {
  description = "k3s node 名 / Tailscale hostname の prefix（インスタンス名を付加して一意化）"
  type        = string
  default     = "gcp-cil"
}

variable "node_taint" {
  description = "ノード taint（クラウド操作専有）。CloudWorkload の toleration `dedicated=gcp-ops` に対応。"
  type        = string
  default     = "dedicated=gcp-ops:NoSchedule"
}

variable "service_account_email" {
  description = "VM にアタッチする SA（metadata 経由でワークロードが GCP を操作＝AWS instance profile 相当）。空なら default compute SA。"
  type        = string
  default     = ""
}

variable "scopes" {
  description = "SA スコープ。cloud-platform（実権限は IAM ロールで絞る）。"
  type        = list(string)
  default     = ["cloud-platform"]
}

# --- k3s join ---
variable "k3s_cp_host" {
  description = "k3s control-plane(rpi0) の到達先。MagicDNS FQDN 推奨。tls-san 済みが前提。"
  type        = string
  default     = "raspberrypi-0.example.ts.net"
}

variable "k3s_cp_port" {
  description = "k3s API port"
  type        = number
  default     = 6443
}

variable "k3s_version" {
  description = "k3s agent バージョン(server=rpi0 と一致)"
  type        = string
  default     = "v1.36.2+k3s1"
}

variable "k3s_token" {
  description = "k3s node-token。秘匿。コミットしない。"
  type        = string
  sensitive   = true
}

# --- Tailscale ---
variable "tailscale_authkey" {
  description = "Tailscale auth key(tskey-...)。秘匿。コミットしない。"
  type        = string
  sensitive   = true
}
