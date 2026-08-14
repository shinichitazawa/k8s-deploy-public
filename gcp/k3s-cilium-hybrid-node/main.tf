# default compute SA（var 未指定時に使用）
data "google_compute_default_service_account" "default" {}

locals {
  sa_email = var.service_account_email != "" ? var.service_account_email : data.google_compute_default_service_account.default.email

  startup_script = templatefile("${path.module}/templates/startup-script.sh.tftpl", {
    node_name         = var.node_name
    tailscale_authkey = var.tailscale_authkey
    k3s_cp_host       = var.k3s_cp_host
    k3s_cp_port       = var.k3s_cp_port
    k3s_url           = "https://${var.k3s_cp_host}:${var.k3s_cp_port}"
    k3s_version       = var.k3s_version
    k3s_token         = var.k3s_token
    node_taint        = var.node_taint
  })
}

# 専用 VPC + subnet。ingress firewall を作らない＝GCP 既定の deny-all-ingress で egress-only。
# egress は implied-allow + default-internet-gateway route で確保（stateful なので Tailscale 直結OK）。
resource "google_compute_network" "node" {
  name                    = "${var.node_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "node" {
  name          = "${var.node_name}-subnet"
  network       = google_compute_network.node.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr
}

# Instance Template（Spot / Ubuntu / startup-script / SA / 外部IP=egress用）
resource "google_compute_instance_template" "node" {
  name_prefix  = "${var.node_name}-"
  machine_type = var.machine_type

  disk {
    source_image = var.image
    auto_delete  = true
    boot         = true
    disk_size_gb = 10
    disk_type    = "pd-standard"
  }

  network_interface {
    network    = google_compute_network.node.id
    subnetwork = google_compute_subnetwork.node.id
    # ephemeral 外部IP: tailscale/k3s の install に必要な egress を確保（ingress は firewall 無しで閉）
    access_config {}
  }

  metadata = {
    startup-script = local.startup_script
  }

  service_account {
    email  = local.sa_email
    scopes = var.scopes
  }

  # Spot: MIG では termination action=STOP 必須（DELETE 不可）。preempt 時は STOP→MIG が自己修復
  scheduling {
    provisioning_model          = "SPOT"
    preemptible                 = true
    automatic_restart           = false
    instance_termination_action = "STOP"
  }

  labels = {
    purpose = "k3s-cilium-hybrid"
    cloud   = "gcp"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Zonal MIG。cluster-autoscaler(GCE provider)が target_size を管理。
# ★ regional ではなく zonal。GCE CA は zonal MIG の URL(.../zones/<zone>/instanceGroups/<name>)
#   しか parse できず、regional URL(.../regions/<region>/…)を "wrong url" で拒否するため
#   (2026-07 live 検証で確認)。トレードオフ: Spot 在庫は var.zone 単一ゾーンに限られる。
resource "google_compute_instance_group_manager" "node" {
  name               = "${var.node_name}-mig"
  base_instance_name = var.node_name
  zone               = var.zone

  version {
    instance_template = google_compute_instance_template.node.id
  }

  # ゼロスケール: 運用時は 0（CA が pending pod で増やす）。テスト時は 1。
  target_size = var.target_size

  update_policy {
    type                  = "OPPORTUNISTIC"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 1 # zonal: 1 で十分
    max_unavailable_fixed = 0
  }

  lifecycle {
    # cluster-autoscaler / 手動で target_size を変えても TF が戻さない
    ignore_changes = [target_size]
  }
}
