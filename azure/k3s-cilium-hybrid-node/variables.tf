variable "subscription_id" {
  description = "Azure サブスクリプション ID"
  type        = string
}

variable "location" {
  description = "Azure リージョン"
  type        = string
  default     = "japaneast"
}

variable "resource_group_name" {
  description = "作成する Resource Group 名"
  type        = string
  default     = "k3s-cilium-hybrid"
}

variable "vm_size" {
  description = "ARM burstable。1GiB(B2pts_v2)では k3s+Cilium のブート負荷で Cilium が起動ループに入る(2026-08 実測: load 10/2vCPU で 28 分収束せず)。4GiB 以上を推奨。"
  type        = string
  default     = "Standard_B2pls_v2"
}

variable "image_sku" {
  description = "Ubuntu 24.04 の SKU。x86=server(Gen2) / arm64=server-arm64。vm_size の arch に合わせる。"
  type        = string
  default     = "server-arm64"
}

variable "instances" {
  description = "VMSS 台数。ゼロスケールは 0（CA が起こす）。テストは 1。"
  type        = number
  default     = 1
}

variable "admin_username" {
  description = "VM 管理ユーザー名"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = "VM の admin SSH 公開鍵（Azure は Linux VM に鍵 or パスワード必須。運用は Tailscale SSH）"
  type        = string
}

variable "vnet_cidr" {
  type    = string
  default = "10.123.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.123.1.0/24"
}

variable "node_name" {
  type    = string
  default = "azure-cil"
}

variable "node_taint" {
  description = "ノード taint（\"key=value:effect\"）。CloudWorkload の toleration dedicated=azure-ops に対応。空文字で taint 無し。"
  type        = string
  default     = "dedicated=azure-ops:NoSchedule"

  # locals.ca_node_template_tags が最初の "=" で key/value を分割するため、形式を plan 時に強制する。
  # （不正形式だと CA 用タグが黙って壊れた値になるのを防ぐ）
  validation {
    condition     = var.node_taint == "" || can(regex("^[^=]+=[^=]*:(NoSchedule|PreferNoSchedule|NoExecute)$", var.node_taint))
    error_message = "node_taint は \"key=value:effect\"（effect は NoSchedule / PreferNoSchedule / NoExecute）か、空文字にしてください。"
  }
}

# --- k3s join ---
variable "k3s_cp_host" {
  description = "k3s CP(rpi0) の MagicDNS FQDN（tls-san 済み）"
  type        = string
  default     = "raspberrypi-0.example.ts.net"
}

variable "k3s_cp_port" {
  type    = number
  default = 6443
}

variable "k3s_version" {
  type    = string
  default = "v1.36.2+k3s1"
}

variable "k3s_token" {
  description = "k3s node-token。秘匿。"
  type        = string
  sensitive   = true
}

variable "tailscale_authkey" {
  description = "Tailscale auth key。秘匿。"
  type        = string
  sensitive   = true
}

variable "ssh_ingress_cidrs" {
  description = "SSH(22) を許可する CIDR。運用は Tailscale SSH 経由を推奨、これは fallback(AWS モジュールと同既定)"
  type        = list(string)
  default     = ["203.0.113.101/32"]
}

variable "public_ip" {
  description = "true=各インスタンスに public IP を付与(共有 egress)。false=完全 private(public IP 無し、NAT Gateway 経由 egress)。既定は現状維持の true"
  type        = bool
  default     = true
}

variable "nat_type" {
  description = "public_ip=false(完全private)時の egress 方式。instance=小型NAT VM(B1s・既定・安価)、gateway=マネージド NAT Gateway。public_ip=true では未使用"
  type        = string
  default     = "instance"
  validation {
    condition     = contains(["instance", "gateway"], var.nat_type)
    error_message = "nat_type must be \"instance\" or \"gateway\"."
  }
}
